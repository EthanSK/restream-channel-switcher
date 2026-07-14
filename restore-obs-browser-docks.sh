#!/usr/bin/env bash
# Restore selected OBS Custom Browser Docks (defaults: "set channels", "chat").
# The dock menu items expose AXPress while their parent menu is closed, so this
# command never opens the Docks menu, steals focus, or sends keyboard input.

set -uo pipefail

TARGET_DOCK_TITLES=("set channels" "chat")
LOG_DIR="${RESTORE_OBS_DOCKS_LOG_DIR:-${HOME}/Library/Logs/restore-obs-browser-docks}"
LOG_RETENTION_DAYS=7
LOCK_DIR="${RESTORE_OBS_DOCKS_LOCK_DIR:-${TMPDIR:-/tmp}/com.ethansk.restore-obs-browser-docks.lock}"
OSASCRIPT_BIN="${RESTORE_OBS_DOCKS_OSASCRIPT:-/usr/bin/osascript}"
LOCK_OWNED=0
SESSION=""

cleanup_logs() {
  [[ -d "$LOG_DIR" ]] || return 0
  find "$LOG_DIR" -type f -name '*.ndjson' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

log_event() {
  local ts log_file json
  ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
  log_file="${LOG_DIR}/$(date "+%Y-%m-%d").ndjson"
  json=$(jq -cn --arg ts "$ts" --arg session "$SESSION" --arg pid "$$" --args '
    reduce ($ARGS.positional | _nwise(2)) as $pair
      ({ts:$ts, session:$session, pid:$pid}; .[$pair[0]] = $pair[1])
  ' -- "$@") || return 0
  printf '%s\n' "$json" >> "$log_file"
}

release_lock() {
  local owner_pid=""
  (( LOCK_OWNED == 1 )) || return 0
  [[ -f "$LOCK_DIR/pid" ]] && owner_pid=$(<"$LOCK_DIR/pid")
  if [[ "$owner_pid" == "$$" ]]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  LOCK_OWNED=0
}

acquire_lock() {
  local owner_pid=""
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_OWNED=1
    log_event stage lock result acquired reason new-lock
    return 0
  fi

  [[ -f "$LOCK_DIR/pid" ]] && owner_pid=$(<"$LOCK_DIR/pid")
  if [[ -z "$owner_pid" ]]; then
    log_event stage lock result skipped reason owner-record-not-ready
    return 1
  fi
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
    log_event stage lock result skipped reason active-owner owner_pid "$owner_pid"
    return 1
  fi

  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_OWNED=1
    log_event stage lock result acquired reason stale-lock-recovered
    return 0
  fi

  log_event stage lock result skipped reason acquisition-failed
  return 1
}

restore_docks() {
  "$OSASCRIPT_BIN" - "${TARGET_DOCK_TITLES[@]}" 2>&1 <<'APPLESCRIPT'
on menuItemIsChecked(dockItem)
    tell application "System Events"
        set markValue to missing value
        try
            set markValue to value of attribute "AXMenuItemMarkChar" of dockItem
        end try
        return not (markValue is missing value or markValue is "")
    end tell
end menuItemIsChecked

on cancelDocksMenuIfOpen()
    tell application "System Events"
        if not (exists application process "OBS") then return true
        tell application process "OBS"
            set docksItem to menu bar item "Docks" of menu bar 1
            set menuIsOpen to false
            try
                set menuIsOpen to value of attribute "AXSelected" of docksItem
            end try
            if not menuIsOpen then return true

            try
                perform action "AXCancel" of menu 1 of docksItem
                delay 0.2
                return not (value of attribute "AXSelected" of docksItem)
            on error
                return false
            end try
        end tell
    end tell
end cancelDocksMenuIfOpen

on run dockNames
    tell application "System Events"
        if not (exists application process "OBS") then return "status=skipped reason=obs-not-running"
    end tell

    try
        if not my cancelDocksMenuIfOpen() then error "Could not dismiss the pre-existing OBS Docks menu" number 1001

        tell application "System Events"
            tell application process "OBS"
                set docksItem to menu bar item "Docks" of menu bar 1
                set openedCount to 0
                set alreadyVisibleCount to 0
                set missingCount to 0
                set failedCount to 0

                repeat with dockName in dockNames
                    set dockTitle to contents of dockName
                    set docksMenu to menu 1 of docksItem
                    if not (exists menu item dockTitle of docksMenu) then
                        set missingCount to missingCount + 1
                    else
                        set dockItem to menu item dockTitle of docksMenu
                        if my menuItemIsChecked(dockItem) then
                            set alreadyVisibleCount to alreadyVisibleCount + 1
                        else
                            perform action "AXPress" of dockItem
                            delay 0.5
                            set verifiedDockItem to menu item dockTitle of menu 1 of docksItem
                            if my menuItemIsChecked(verifiedDockItem) then
                                set openedCount to openedCount + 1
                            else
                                set failedCount to failedCount + 1
                            end if
                        end if
                    end if
                end repeat
            end tell
        end tell

        if not my cancelDocksMenuIfOpen() then error "OBS Docks menu remained open after the direct dock actions" number 1002
        if missingCount > 0 or failedCount > 0 then error "Dock verification failed: missing_count=" & missingCount & " failed_count=" & failedCount number 1003
        return "status=ok opened_count=" & openedCount & " already_visible_count=" & alreadyVisibleCount & " missing_count=0 failed_count=0"
    on error errorMessage number errorNumber
        set menuWasDismissed to my cancelDocksMenuIfOpen()
        if not menuWasDismissed then set errorMessage to errorMessage & "; OBS Docks menu cleanup also failed"
        error errorMessage number errorNumber
    end try
end run
APPLESCRIPT
}

print_help() {
  cat <<'EOF'
Usage: restore-obs-browser-docks [DOCK_TITLE ...]

Restores the named OBS Custom Browser Docks, defaulting to "set channels" and
"chat" when no titles are passed. The command invokes each closed-menu
Accessibility action directly; it never opens the Docks menu, changes the
foreground app, or sends keyboard input.
EOF
}

main() {
  if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    print_help
    return 0
  fi
  if (( $# > 0 )); then
    TARGET_DOCK_TITLES=("$@")
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required for structured diagnostics." >&2
    return 1
  fi
  if [[ ! -x "$OSASCRIPT_BIN" ]]; then
    echo "error: osascript is unavailable at $OSASCRIPT_BIN" >&2
    return 1
  fi

  mkdir -p "$LOG_DIR"
  cleanup_logs
  SESSION="$(date "+%Y%m%dT%H%M%S")-$$-${RANDOM}"
  log_event stage invocation result started target_count "${#TARGET_DOCK_TITLES[@]}"

  if ! acquire_lock; then
    echo "OBS browser docks: skipped (another invocation owns the automation lock)"
    return 0
  fi

  local output exit_code=0
  output=$(restore_docks) || exit_code=$?
  if (( exit_code == 0 )); then
    echo "OBS browser docks: $output"
    log_event stage automation result ok detail "$output"
    return 0
  fi

  echo "warning: OBS browser dock restoration failed once and will not retry: $output" >&2
  log_event stage automation result failed exit_code "$exit_code" detail "$output"
  return 1
}

trap release_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
