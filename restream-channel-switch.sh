#!/usr/bin/env bash
# restream-channel-switch — toggle Restream streaming destinations on/off
# based on user-defined "flags" (labels) that map to sets of channels.
#
# Pure bash. Requires: curl, security (macOS), jq.
#
# Usage:
#   restream-channel-switch --auth
#   restream-channel-switch --setup
#   restream-channel-switch --list
#   restream-channel-switch --flags
#   restream-channel-switch --flag wreathen [--dry-run]
#   restream-channel-switch --enable "YouTube" --disable "Twitch"
#   restream-channel-switch --status
#   restream-channel-switch --reset-creds
#   restream-channel-switch --help
#
# Tokens + client credentials + flag map live in the macOS Keychain.
# Service name is "com.restream-profile" for continuity with older installs
# (pre-rename). Do NOT change it — that would invalidate existing auth.
# Refresh tokens rotate — we persist each new refresh_token back to the keychain.
#
# API reference:
#   Authorize:  https://api.restream.io/login
#   Token:      https://api.restream.io/oauth/token
#   List:       GET   https://api.restream.io/v2/user/channel/all
#   Update:     PATCH https://api.restream.io/v2/user/channel/{id}   body: {"active": bool}
#   Profile:    GET   https://api.restream.io/v2/user/profile
# Scopes: profile.read channels.read channels.write

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# NOTE: keychain service name is legacy; kept as "com.restream-profile" so that
# existing users don't have to re-auth after the repo/binary rename.
KEYCHAIN_SERVICE="com.restream-profile"
KC_ACCOUNT_TOKENS="tokens"
KC_ACCOUNT_CLIENT="client"
KC_ACCOUNT_STATE="last-state"
KC_ACCOUNT_FLAGS="channel-flags"

AUTHORIZE_URL="https://api.restream.io/login"
TOKEN_URL="https://api.restream.io/oauth/token"
API_BASE="https://api.restream.io/v2"

REDIRECT_PORT=8976
REDIRECT_URI="http://localhost:${REDIRECT_PORT}/callback"
SCOPES="profile.read channels.read channels.write"

LOG_DIR="${HOME}/Library/Logs/restream-channel-switch"
LOG_FILE="${LOG_DIR}/toggle.log"
LOG_MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB

USER_AGENT="restream-channel-switch/2.0 (+https://github.com/EthanSK/restream-channel-switcher)"

EXIT_OK=0
EXIT_AUTH=1
EXIT_NETWORK=2
EXIT_NO_MATCH=3
EXIT_PARTIAL=4
EXIT_NO_SETUP=5

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command '$1' not found in PATH" >&2
    echo "       install it (e.g. 'brew install $1') and try again" >&2
    exit 127
  }
}
require_cmd curl
require_cmd jq
require_cmd security

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

rotate_log_if_needed() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}

log_event() {
  # log_event key1=val1 key2=val2 ...  (values are treated as strings)
  rotate_log_if_needed
  local ts
  ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
  local json
  json=$(jq -cn --arg ts "$ts" --args '
    reduce ($ARGS.positional | _nwise(2)) as $p ({ts: $ts}; .[$p[0]] = $p[1])
  ' -- "$@") || return 0
  printf '%s\n' "$json" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Keychain helpers
# ---------------------------------------------------------------------------
kc_get() {
  # $1 = account; prints value to stdout, returns 1 if not found
  security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null
}

kc_set() {
  # $1 = account, $2 = value
  security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$1" -w "$2" >/dev/null 2>&1
}

kc_delete() {
  security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Credential + token persistence
# ---------------------------------------------------------------------------
# Globals populated by load_client_creds / load_tokens:
CLIENT_ID=""
CLIENT_SECRET=""
ACCESS_TOKEN=""
REFRESH_TOKEN=""
ACCESS_EXPIRES_AT=0
FLAG_MAP_JSON=""

load_client_creds() {
  local raw
  raw=$(kc_get "$KC_ACCOUNT_CLIENT") || return 1
  [[ -n "$raw" ]] || return 1
  CLIENT_ID=$(printf '%s' "$raw" | jq -r '.client_id // empty')
  CLIENT_SECRET=$(printf '%s' "$raw" | jq -r '.client_secret // empty')
  [[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]]
}

save_client_creds() {
  local json
  json=$(jq -cn --arg id "$1" --arg sec "$2" '{client_id:$id, client_secret:$sec}')
  kc_set "$KC_ACCOUNT_CLIENT" "$json"
}

load_tokens() {
  local raw
  raw=$(kc_get "$KC_ACCOUNT_TOKENS") || return 1
  [[ -n "$raw" ]] || return 1
  ACCESS_TOKEN=$(printf '%s' "$raw" | jq -r '.access_token // empty')
  REFRESH_TOKEN=$(printf '%s' "$raw" | jq -r '.refresh_token // empty')
  ACCESS_EXPIRES_AT=$(printf '%s' "$raw" | jq -r '.access_expires_at // 0')
  [[ -n "$ACCESS_TOKEN" && -n "$REFRESH_TOKEN" ]]
}

save_tokens() {
  # $1=access, $2=refresh, $3=expires_at (unix seconds)
  local json
  json=$(jq -cn --arg a "$1" --arg r "$2" --argjson e "$3" \
    '{access_token:$a, refresh_token:$r, access_expires_at:$e}')
  kc_set "$KC_ACCOUNT_TOKENS" "$json"
  ACCESS_TOKEN="$1"; REFRESH_TOKEN="$2"; ACCESS_EXPIRES_AT="$3"
}

save_last_state() {
  kc_set "$KC_ACCOUNT_STATE" "$1"
}

load_last_state() {
  kc_get "$KC_ACCOUNT_STATE"
}

load_flag_map() {
  local raw
  raw=$(kc_get "$KC_ACCOUNT_FLAGS") || return 1
  [[ -n "$raw" ]] || return 1
  printf '%s' "$raw" | jq -e 'has("channel_flags")' >/dev/null 2>&1 || return 1
  FLAG_MAP_JSON="$raw"
}

save_flag_map() {
  kc_set "$KC_ACCOUNT_FLAGS" "$1"
}

# ---------------------------------------------------------------------------
# OAuth flow
# ---------------------------------------------------------------------------
prompt_client_creds() {
  echo "Restream OAuth app credentials are required (one-time)."
  echo "Create an app at https://developers.restream.io/apps"
  echo "  - Set Redirect URI to: $REDIRECT_URI"
  echo "  - Scopes needed: $SCOPES"
  echo
  printf 'Client ID: '
  local cid; read -r cid
  printf 'Client Secret: '
  local csec; read -r csec
  if [[ -z "$cid" || -z "$csec" ]]; then
    echo "Client ID and Client Secret are required." >&2
    exit "$EXIT_AUTH"
  fi
  save_client_creds "$cid" "$csec"
  CLIENT_ID="$cid"; CLIENT_SECRET="$csec"
  echo "Stored in macOS Keychain (service=$KEYCHAIN_SERVICE, account=client)."
}

urlencode() {
  jq -rn --arg s "$1" '$s|@uri'
}

gen_state() {
  openssl rand 24 | base64 | tr '+/' '-_' | tr -d '=\n'
}

CB_CODE=""
CB_STATE=""
CB_ERROR=""

await_oauth_callback() {
  local tmp
  tmp=$(mktemp -t restream-cb.XXXXXX)
  trap 'rm -f "$tmp"' RETURN

  {
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: text/html; charset=utf-8\r\n'
    printf 'Connection: close\r\n'
    printf 'Content-Length: 94\r\n'
    printf '\r\n'
    printf '<html><body><h3>Authorization captured. You can close this tab.</h3></body></html>'
  } | nc -l "$REDIRECT_PORT" > "$tmp" 2>/dev/null || true

  local req_line query
  req_line=$(head -n1 "$tmp" | tr -d '\r')
  query="${req_line#GET }"
  query="${query%% HTTP/*}"
  query="${query#*\?}"
  local pair key val
  while IFS='&' read -ra pairs <<<"$query"; do
    for pair in "${pairs[@]}"; do
      key="${pair%%=*}"
      val="${pair#*=}"
      val=$(printf '%b' "${val//%/\\x}")
      case "$key" in
        code)  CB_CODE="$val" ;;
        state) CB_STATE="$val" ;;
        error) CB_ERROR="$val" ;;
      esac
    done
  done
}

do_auth_flow() {
  if ! load_client_creds; then
    prompt_client_creds
  fi

  local state
  state=$(gen_state)

  local auth_url
  auth_url="${AUTHORIZE_URL}?response_type=code"
  auth_url+="&client_id=$(urlencode "$CLIENT_ID")"
  auth_url+="&redirect_uri=$(urlencode "$REDIRECT_URI")"
  auth_url+="&state=$(urlencode "$state")"
  auth_url+="&scope=$(urlencode "$SCOPES")"

  echo "Opening browser for Restream authorization..."
  echo "If it doesn't open, visit:"
  echo "  $auth_url"
  echo

  await_oauth_callback &
  local cb_pid=$!
  sleep 0.3
  open "$auth_url" 2>/dev/null || true

  local waited=0
  while kill -0 "$cb_pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if (( waited > 300 )); then
      kill "$cb_pid" 2>/dev/null || true
      echo "Timed out waiting for OAuth callback." >&2
      exit "$EXIT_AUTH"
    fi
  done
  wait "$cb_pid" 2>/dev/null || true

  if [[ -n "$CB_ERROR" ]]; then
    echo "OAuth error: $CB_ERROR" >&2
    exit "$EXIT_AUTH"
  fi
  if [[ "$CB_STATE" != "$state" ]]; then
    echo "OAuth state mismatch -- aborting (possible CSRF)." >&2
    exit "$EXIT_AUTH"
  fi
  if [[ -z "$CB_CODE" ]]; then
    echo "No authorization code returned." >&2
    exit "$EXIT_AUTH"
  fi

  exchange_code_for_tokens "$CB_CODE"
  echo "Tokens saved to Keychain."
  echo "Next: run '--setup' to map your channels to flags."
  log_event action auth result ok
}

# ---------------------------------------------------------------------------
# Token exchange / refresh
# ---------------------------------------------------------------------------
_token_post() {
  local resp status body
  resp=$(curl -sS -w $'\n%{http_code}' -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    -H "User-Agent: $USER_AGENT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    "$@" \
    "$TOKEN_URL")
  status="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$status" != "200" ]]; then
    echo "token request failed ($status): $body" >&2
    return 1
  fi
  local access refresh expires_in now expires_at
  access=$(printf '%s' "$body" | jq -r '.access_token // .accessToken // empty')
  refresh=$(printf '%s' "$body" | jq -r '.refresh_token // .refreshToken // empty')
  expires_in=$(printf '%s' "$body" | jq -r '.expires_in // .accessTokenExpiresIn // 3600')
  if [[ -z "$access" || -z "$refresh" ]]; then
    echo "token response missing fields: $body" >&2
    return 1
  fi
  now=$(date +%s)
  expires_at=$(( now + expires_in - 60 ))
  save_tokens "$access" "$refresh" "$expires_at"
}

exchange_code_for_tokens() {
  _token_post \
    -d "grant_type=authorization_code" \
    --data-urlencode "redirect_uri=$REDIRECT_URI" \
    --data-urlencode "code=$1" || exit "$EXIT_AUTH"
}

refresh_access_token() {
  _token_post \
    -d "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$REFRESH_TOKEN"
}

ensure_valid_tokens() {
  if ! load_client_creds; then
    echo "No client credentials found. Run --auth first." >&2
    exit "$EXIT_AUTH"
  fi
  if ! load_tokens; then
    echo "No tokens found. Run --auth first." >&2
    exit "$EXIT_AUTH"
  fi
  local now
  now=$(date +%s)
  if (( ACCESS_EXPIRES_AT <= now )); then
    if ! refresh_access_token; then
      log_event action refresh result fail
      echo "Refresh failed. Re-run --auth." >&2
      exit "$EXIT_AUTH"
    fi
    log_event action refresh result ok
  fi
}

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
API_STATUS=0
API_BODY=""

api_call() {
  local method="$1" path="$2" body="${3-}"
  local retried=0
  while :; do
    local args=(-sS -X "$method" -w $'\n%{http_code}' \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "User-Agent: $USER_AGENT" \
      -H "Accept: application/json")
    if [[ -n "$body" ]]; then
      args+=(-H "Content-Type: application/json" --data "$body")
    fi
    local resp
    resp=$(curl "${args[@]}" "${API_BASE}${path}")
    API_STATUS="${resp##*$'\n'}"
    API_BODY="${resp%$'\n'*}"
    if [[ "$API_STATUS" == "401" && $retried -eq 0 ]]; then
      retried=1
      if refresh_access_token; then
        continue
      else
        log_event action refresh-on-401 result fail
        echo "Authorization error and refresh failed. Re-run --auth." >&2
        exit "$EXIT_AUTH"
      fi
    fi
    return 0
  done
}

fetch_channels() {
  api_call GET /user/channel/all
  if [[ "$API_STATUS" != "200" ]]; then
    echo "API error ($API_STATUS) GET /user/channel/all: $API_BODY" >&2
    log_event action api-error path /user/channel/all status "$API_STATUS"
    exit "$EXIT_NETWORK"
  fi
  CHANNELS_JSON="$API_BODY"
}

set_channel_active() {
  api_call PATCH "/user/channel/$1" "{\"active\": $2}"
  [[ "$API_STATUS" == "200" || "$API_STATUS" == "204" ]]
}

fetch_profile() {
  api_call GET /user/profile
  if [[ "$API_STATUS" != "200" ]]; then
    echo "Profile check failed ($API_STATUS): $API_BODY" >&2
    return 1
  fi
  PROFILE_JSON="$API_BODY"
}

# ---------------------------------------------------------------------------
# Channel lookup helpers
# ---------------------------------------------------------------------------
find_channel_by_name() {
  local json="$1" name="$2"
  local needle
  needle=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  local exact
  exact=$(printf '%s' "$json" | jq --arg n "$needle" \
    '[.[] | select((.displayName // "" | ascii_downcase) == $n)]')
  local count
  count=$(printf '%s' "$exact" | jq 'length')
  if (( count >= 1 )); then
    printf '%s' "$exact" | jq '.[0]'
    return 0
  fi
  local subs
  subs=$(printf '%s' "$json" | jq --arg n "$needle" \
    '[.[] | select((.displayName // "" | ascii_downcase) | contains($n))]')
  count=$(printf '%s' "$subs" | jq 'length')
  if (( count == 1 )); then
    printf '%s' "$subs" | jq '.[0]'
    return 0
  fi
  if (( count > 1 )); then
    echo "Ambiguous channel name '$name' -- matches $(printf '%s' "$subs" | jq -c '[.[].displayName]')" >&2
    return 2
  fi
  return 1
}

ENABLED_NAMES=()
DISABLED_NAMES=()
ERRORS_JSON="[]"

apply_toggles() {
  ENABLED_NAMES=()
  DISABLED_NAMES=()
  ERRORS_JSON="[]"

  local id name
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" ]] && continue
    if set_channel_active "$id" true; then
      ENABLED_NAMES+=("$name")
      echo "  ok enabled  $name (id $id)"
    else
      echo "  FAIL enable $name (id $id): $API_STATUS $API_BODY" >&2
      ERRORS_JSON=$(printf '%s' "$ERRORS_JSON" | jq --arg n "$name" --arg s "$API_STATUS" \
        '. + [{channel:$n, op:"enable", status:$s}]')
    fi
  done < <(printf '%s' "$1" | jq -r '.[] | "\(.id)\t\(.displayName)"')

  while IFS=$'\t' read -r id name; do
    [[ -z "$id" ]] && continue
    if set_channel_active "$id" false; then
      DISABLED_NAMES+=("$name")
      echo "  ok disabled $name (id $id)"
    else
      echo "  FAIL disable $name (id $id): $API_STATUS $API_BODY" >&2
      ERRORS_JSON=$(printf '%s' "$ERRORS_JSON" | jq --arg n "$name" --arg s "$API_STATUS" \
        '. + [{channel:$n, op:"disable", status:$s}]')
    fi
  done < <(printf '%s' "$2" | jq -r '.[] | "\(.id)\t\(.displayName)"')
}

# ---------------------------------------------------------------------------
# Flag-map driven logic
# ---------------------------------------------------------------------------
TO_ENABLE_JSON="[]"
TO_DISABLE_JSON="[]"
MATCH_COUNT=0

compute_toggles_for_flag() {
  local flag="$1" channels="$2" flagmap="$3"
  local matched
  matched=$(jq -cn --arg f "$flag" --argjson m "$flagmap" --argjson ch "$channels" '
    ($m.channel_flags // {}) as $cf
    | [$ch[] | select(
        (($cf[(.id|tostring)] // []) | index($f)) != null
      )]
  ')
  MATCH_COUNT=$(printf '%s' "$matched" | jq 'length')

  TO_ENABLE_JSON=$(printf '%s' "$matched" | jq '[.[] | select(.active | not)]')
  TO_DISABLE_JSON=$(jq -cn --argjson all "$channels" --argjson m "$matched" '
    ($m | map(.id)) as $keep
    | [$all[] | select(.active and ((.id as $id | $keep | index($id)) | not))]
  ')
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_list() {
  fetch_channels
  printf '%-6s %-12s %-14s %s\n' "STATE" "ID" "PLATFORM" "NAME"
  printf '%s' "$CHANNELS_JSON" \
    | jq -r 'sort_by(.displayName // "" | ascii_downcase) | .[]
      | [(if .active then "ON " else "off" end),
         (.id // "" | tostring),
         ((.streamingPlatformId // .platformId // "") | tostring),
         (.displayName // "")] | @tsv' \
    | awk -F'\t' '{printf "%-6s %-12s %-14s %s\n", $1, $2, $3, $4}'
  local total active
  total=$(printf '%s' "$CHANNELS_JSON" | jq 'length')
  active=$(printf '%s' "$CHANNELS_JSON" | jq '[.[] | select(.active)] | length')
  printf '\n%d channel(s), %d active.\n' "$total" "$active"
}

cmd_flags() {
  if ! load_flag_map; then
    echo "No flag mapping yet. Run --setup to create one." >&2
    return "$EXIT_NO_SETUP"
  fi
  printf '%s' "$FLAG_MAP_JSON" | jq -r '
    (.channel_flags // {})
    | to_entries
    | map(.value[])
    | group_by(.)
    | map({flag: .[0], count: length})
    | sort_by(.flag)
    | (if length == 0 then
        "(no flags defined yet)"
       else
        (["FLAG","CHANNELS"] | @tsv),
        (.[] | [.flag, (.count|tostring)] | @tsv)
       end)
  ' | awk -F'\t' '{printf "%-24s %s\n", $1, $2}'
}

cmd_flag() {
  local flag="$1" dry="$2"
  if ! load_flag_map; then
    cat >&2 <<EOF
No flag mapping found. Run '--setup' first to choose which channels
belong to which flags. For example:

  restream-channel-switch --setup
  restream-channel-switch --flag $flag
EOF
    log_event action flag flag "$flag" result no-setup
    return "$EXIT_NO_SETUP"
  fi
  fetch_channels

  compute_toggles_for_flag "$flag" "$CHANNELS_JSON" "$FLAG_MAP_JSON"

  if (( MATCH_COUNT == 0 )); then
    echo "No channels are assigned to flag '$flag'." >&2
    echo "Run --setup to assign channels, or --flags to list defined flags." >&2
    log_event action flag flag "$flag" result no-match
    return "$EXIT_NO_MATCH"
  fi

  local en_count dis_count matched_names
  matched_names=$(jq -cn --arg f "$flag" --argjson m "$FLAG_MAP_JSON" --argjson ch "$CHANNELS_JSON" '
    ($m.channel_flags // {}) as $cf
    | [$ch[] | select((($cf[(.id|tostring)] // []) | index($f)) != null) | .displayName]
  ')
  en_count=$(printf '%s' "$TO_ENABLE_JSON" | jq 'length')
  dis_count=$(printf '%s' "$TO_DISABLE_JSON" | jq 'length')

  echo "Flag '$flag':"
  echo "  channels in flag ($MATCH_COUNT): $matched_names"
  echo "  will enable  ($en_count): $(printf '%s' "$TO_ENABLE_JSON" | jq -c '[.[].displayName]')"
  echo "  will disable ($dis_count): $(printf '%s' "$TO_DISABLE_JSON" | jq -c '[.[].displayName]')"

  if [[ "$dry" == "1" ]]; then
    echo "(dry-run; no changes)"
    return "$EXIT_OK"
  fi

  apply_toggles "$TO_ENABLE_JSON" "$TO_DISABLE_JSON"

  local ts state_json
  ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
  state_json=$(jq -cn \
    --arg flag "$flag" --arg ts "$ts" \
    --argjson enabled "$(printf '%s\n' "${ENABLED_NAMES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    --argjson disabled "$(printf '%s\n' "${DISABLED_NAMES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    --argjson errors "$ERRORS_JSON" \
    '{flag:$flag, ts:$ts, enabled:$enabled, disabled:$disabled, errors:$errors}')
  save_last_state "$state_json"

  local err_count
  err_count=$(printf '%s' "$ERRORS_JSON" | jq 'length')
  local result="ok"
  (( err_count > 0 )) && result="partial"
  log_event action flag flag "$flag" result "$result" errors "$err_count"

  if (( err_count > 0 )); then
    echo
    echo "$err_count error(s) during toggle." >&2
    return "$EXIT_PARTIAL"
  fi
  echo
  echo "Flag '$flag' applied."
  return "$EXIT_OK"
}

cmd_enable_disable() {
  fetch_channels

  local to_enable='[]' to_disable='[]'
  local name rc
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local ch
    ch=$(find_channel_by_name "$CHANNELS_JSON" "$name")
    rc=$?
    if (( rc == 1 )); then
      echo "No channel matches '$name'" >&2
      return "$EXIT_NO_MATCH"
    elif (( rc == 2 )); then
      return "$EXIT_NO_MATCH"
    fi
    to_enable=$(jq -cn --argjson a "$to_enable" --argjson c "$ch" '$a + [$c]')
  done <<< "$1"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local ch
    ch=$(find_channel_by_name "$CHANNELS_JSON" "$name")
    rc=$?
    if (( rc == 1 )); then
      echo "No channel matches '$name'" >&2
      return "$EXIT_NO_MATCH"
    elif (( rc == 2 )); then
      return "$EXIT_NO_MATCH"
    fi
    to_disable=$(jq -cn --argjson a "$to_disable" --argjson c "$ch" '$a + [$c]')
  done <<< "$2"

  apply_toggles "$to_enable" "$to_disable"

  local err_count
  err_count=$(printf '%s' "$ERRORS_JSON" | jq 'length')
  local result="ok"
  (( err_count > 0 )) && result="partial"
  log_event action enable-disable result "$result" errors "$err_count"
  if (( err_count > 0 )); then
    return "$EXIT_PARTIAL"
  fi
  return "$EXIT_OK"
}

cmd_status() {
  if fetch_profile; then
    local user id email
    user=$(printf '%s' "$PROFILE_JSON" | jq -r '.username // empty')
    id=$(printf '%s' "$PROFILE_JSON" | jq -r '.id // empty')
    email=$(printf '%s' "$PROFILE_JSON" | jq -r '.email // empty')
    echo "User: $user (id=$id, email=$email)"
  fi
  if load_flag_map; then
    local flag_count
    flag_count=$(printf '%s' "$FLAG_MAP_JSON" | jq -r '
      [(.channel_flags // {}) | to_entries[].value[]] | unique | length')
    echo "Flags defined: $flag_count"
  else
    echo "Flags defined: 0 (run --setup)"
  fi
  local last
  last=$(load_last_state) || last=""
  if [[ -n "$last" ]]; then
    echo
    echo "Last toggle:"
    printf '  ts:       %s\n' "$(printf '%s' "$last" | jq -r '.ts // ""')"
    printf '  flag:     %s\n' "$(printf '%s' "$last" | jq -r '.flag // .profile // ""')"
    printf '  enabled:  %s\n' "$(printf '%s' "$last" | jq -c '.enabled // []')"
    printf '  disabled: %s\n' "$(printf '%s' "$last" | jq -c '.disabled // []')"
    local errs
    errs=$(printf '%s' "$last" | jq -c '.errors // []')
    [[ "$errs" != "[]" ]] && printf '  errors:   %s\n' "$errs"
  else
    echo
    echo "No previous toggle recorded."
  fi
  echo
  echo "Current channel state:"
  cmd_list
}

# ---------------------------------------------------------------------------
# Interactive setup TUI
# ---------------------------------------------------------------------------
# Pure bash + ANSI escapes. No curses / whiptail / dialog.
#
# Module-level state:
#   SETUP_NAMES[]        displayName per row
#   SETUP_IDS[]          channel id per row
#   SETUP_PLATFORMS[]    platform label per row
#   SETUP_ACTIVE[]       current active state per row ("true"/"false")
#   SETUP_ROW_FLAGS[]    comma-separated flag list per row (working copy)
#   SETUP_FLAGS[]        sorted unique list of known flags
#   SETUP_ACTIVE_FLAG    currently-focused flag
#   SETUP_CURSOR         current row index
#   SETUP_TOP            top row of viewport

SETUP_NAMES=()
SETUP_IDS=()
SETUP_PLATFORMS=()
SETUP_ACTIVE=()
SETUP_ROW_FLAGS=()
SETUP_FLAGS=()
SETUP_ACTIVE_FLAG=""
SETUP_CURSOR=0
SETUP_TOP=0
SETUP_MSG=""

tui_cleanup() {
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  stty sane 2>/dev/null || true
}

# Recompute SETUP_FLAGS from SETUP_ROW_FLAGS (unique, sorted), preserving an
# empty-but-created flag if it's the current SETUP_ACTIVE_FLAG (so that
# creating a new flag doesn't vanish before the user toggles anything).
setup_recompute_flags() {
  local all=()
  local r f
  for r in "${SETUP_ROW_FLAGS[@]}"; do
    [[ -z "$r" ]] && continue
    IFS=',' read -ra parts <<<"$r"
    for f in "${parts[@]}"; do
      f="${f#"${f%%[![:space:]]*}"}"
      f="${f%"${f##*[![:space:]]}"}"
      [[ -z "$f" ]] && continue
      all+=("$f")
    done
  done
  if [[ -n "$SETUP_ACTIVE_FLAG" ]]; then
    all+=("$SETUP_ACTIVE_FLAG")
  fi
  if (( ${#all[@]} == 0 )); then
    SETUP_FLAGS=()
  else
    # Bash 3 portable: use printf + sort -u
    local sorted
    sorted=$(printf '%s\n' "${all[@]}" | sort -u)
    SETUP_FLAGS=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && SETUP_FLAGS+=("$line")
    done <<<"$sorted"
  fi
  # keep active flag valid
  if [[ -n "$SETUP_ACTIVE_FLAG" ]]; then
    local found=0
    for f in "${SETUP_FLAGS[@]}"; do
      [[ "$f" == "$SETUP_ACTIVE_FLAG" ]] && { found=1; break; }
    done
    (( found )) || SETUP_ACTIVE_FLAG=""
  fi
  if [[ -z "$SETUP_ACTIVE_FLAG" && ${#SETUP_FLAGS[@]} -gt 0 ]]; then
    SETUP_ACTIVE_FLAG="${SETUP_FLAGS[0]}"
  fi
}

row_has_flag() {
  local r="$1" flag="$2"
  local rf="${SETUP_ROW_FLAGS[$r]:-}"
  [[ -z "$rf" ]] && return 1
  local f
  IFS=',' read -ra parts <<<"$rf"
  for f in "${parts[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"
    f="${f%"${f##*[![:space:]]}"}"
    [[ "$f" == "$flag" ]] && return 0
  done
  return 1
}

toggle_row_flag() {
  local r="$1" flag="$2"
  local rf="${SETUP_ROW_FLAGS[$r]:-}"
  local out=()
  local found=0 f
  if [[ -n "$rf" ]]; then
    IFS=',' read -ra parts <<<"$rf"
    for f in "${parts[@]}"; do
      f="${f#"${f%%[![:space:]]*}"}"
      f="${f%"${f##*[![:space:]]}"}"
      [[ -z "$f" ]] && continue
      if [[ "$f" == "$flag" ]]; then
        found=1
      else
        out+=("$f")
      fi
    done
  fi
  (( ! found )) && out+=("$flag")
  local joined="" i
  for ((i=0; i<${#out[@]}; i++)); do
    if (( i == 0 )); then joined="${out[$i]}"; else joined+=", ${out[$i]}"; fi
  done
  SETUP_ROW_FLAGS[$r]="$joined"
}

format_row_flags() {
  local r="$1" is_current="$2"
  local rf="${SETUP_ROW_FLAGS[$r]:-}"
  if [[ -z "$rf" ]]; then
    printf '(none)'
    return
  fi
  local f out="" i=0
  IFS=',' read -ra parts <<<"$rf"
  for f in "${parts[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"
    f="${f%"${f##*[![:space:]]}"}"
    [[ -z "$f" ]] && continue
    (( i > 0 )) && out+=", "
    if [[ "$f" == "$SETUP_ACTIVE_FLAG" ]]; then
      out+=$'\e[1;36m'"$f"$'\e[0m'
      [[ "$is_current" == "1" ]] && out+=$'\e[7m'
    else
      out+="$f"
    fi
    i=$((i+1))
  done
  printf '%s' "$out"
}

setup_active_flag_index() {
  local i=0 f
  for f in "${SETUP_FLAGS[@]}"; do
    i=$((i+1))
    [[ "$f" == "$SETUP_ACTIVE_FLAG" ]] && { echo "$i"; return; }
  done
  echo 0
}

tui_draw() {
  local rows cols
  rows=$(tput lines)
  cols=$(tput cols)
  tput clear

  tput cup 0 0
  printf '\e[1mRESTREAM CHANNEL SETUP\e[0m'
  tput cup 2 0
  printf 'Map each channel to one or more flags. A flag is just a label you pick'
  tput cup 3 0
  printf '(e.g. "wreathen", "3000ad", "main"). Later, `--flag <name>` enables'
  tput cup 4 0
  printf 'every channel tagged with <name> and disables the rest.'
  tput cup 6 0
  printf '\e[2mUp/Dn or j/k  move   Space  toggle channel in active flag   Tab  next flag\e[0m'
  tput cup 7 0
  printf '\e[2mn  new flag    d  delete active flag    s/q  save & quit    Esc  cancel\e[0m'

  local header_row=9
  tput cup "$header_row" 0
  printf '  \e[1m%-3s %-30s  %-3s %-10s  %s\e[0m' "SEL" "CHANNEL" "ON" "PLATFORM" "FLAGS"

  local n=${#SETUP_NAMES[@]}
  local footer_rows=5
  local avail=$(( rows - header_row - 2 - footer_rows ))
  (( avail < 3 )) && avail=3

  if (( SETUP_CURSOR < SETUP_TOP )); then SETUP_TOP=$SETUP_CURSOR; fi
  if (( SETUP_CURSOR >= SETUP_TOP + avail )); then SETUP_TOP=$(( SETUP_CURSOR - avail + 1 )); fi
  (( SETUP_TOP < 0 )) && SETUP_TOP=0

  local i y=0
  for (( i=SETUP_TOP; i<n && y<avail; i++, y++ )); do
    local row=$(( header_row + 1 + y ))
    tput cup "$row" 0
    local marker="  "
    local is_current=0
    if (( i == SETUP_CURSOR )); then
      marker="> "
      is_current=1
      printf '\e[7m'
    fi
    local in_flag="[ ]"
    if [[ -n "$SETUP_ACTIVE_FLAG" ]] && row_has_flag "$i" "$SETUP_ACTIVE_FLAG"; then
      if (( is_current )); then
        in_flag=$'\e[1;32m[x]\e[0m\e[7m'
      else
        in_flag=$'\e[1;32m[x]\e[0m'
      fi
    fi
    local live="off"
    if [[ "${SETUP_ACTIVE[$i]}" == "true" ]]; then
      if (( is_current )); then
        live=$'\e[32mON\e[0m\e[7m'
      else
        live=$'\e[32mON\e[0m'
      fi
    fi
    local name="${SETUP_NAMES[$i]}"
    (( ${#name} > 30 )) && name="${name:0:27}..."
    local plat="${SETUP_PLATFORMS[$i]}"
    (( ${#plat} > 10 )) && plat="${plat:0:10}"
    printf '%s%s %-30s  %-3b %-10s  ' "$marker" "$in_flag" "$name" "$live" "$plat"
    format_row_flags "$i" "$is_current"
    (( is_current )) && printf '\e[0m'
  done

  local ftop=$(( rows - footer_rows ))
  tput cup "$ftop" 0
  printf '\e[2m─────────────────────────────────────────────────────────────\e[0m'

  tput cup $(( ftop + 1 )) 0
  if (( ${#SETUP_FLAGS[@]} == 0 )); then
    printf 'Active flag: \e[33m(none yet — press n to create one)\e[0m'
  else
    printf 'Active flag: \e[1;36m%s\e[0m   (%s of %d — Tab cycles)' \
      "$SETUP_ACTIVE_FLAG" \
      "$(setup_active_flag_index)" \
      "${#SETUP_FLAGS[@]}"
  fi

  tput cup $(( ftop + 2 )) 0
  if (( ${#SETUP_FLAGS[@]} > 0 )); then
    local joined="" i=0 f
    for f in "${SETUP_FLAGS[@]}"; do
      (( i > 0 )) && joined+=", "
      joined+="$f"
      i=$((i+1))
    done
    printf 'All flags: %s' "$joined"
  else
    printf 'All flags: (none)'
  fi

  if [[ -n "$SETUP_MSG" ]]; then
    tput cup $(( ftop + 3 )) 0
    printf '\e[33m%s\e[0m' "$SETUP_MSG"
  fi
}

tui_prompt_flag_name() {
  local rows
  rows=$(tput lines)
  tput cup $(( rows - 1 )) 0
  tput el
  tput cnorm
  stty sane
  printf 'New flag name (letters/digits/_/./-): '
  IFS= read -r REPLY
  tput civis
  stty -echo
}

setup_cycle_active_flag() {
  local n=${#SETUP_FLAGS[@]}
  (( n == 0 )) && return
  local idx=0 i
  for (( i=0; i<n; i++ )); do
    if [[ "${SETUP_FLAGS[$i]}" == "$SETUP_ACTIVE_FLAG" ]]; then
      idx=$(( (i + 1) % n ))
      break
    fi
  done
  SETUP_ACTIVE_FLAG="${SETUP_FLAGS[$idx]}"
}

setup_delete_active_flag() {
  local flag="$SETUP_ACTIVE_FLAG"
  [[ -z "$flag" ]] && return
  local i
  for (( i=0; i<${#SETUP_ROW_FLAGS[@]}; i++ )); do
    if row_has_flag "$i" "$flag"; then
      toggle_row_flag "$i" "$flag"
    fi
  done
  SETUP_ACTIVE_FLAG=""
  setup_recompute_flags
  SETUP_MSG="Deleted flag '$flag'"
}

setup_new_flag() {
  tui_prompt_flag_name
  local name="$REPLY"
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  if [[ -z "$name" ]]; then
    SETUP_MSG="Cancelled: empty flag name."
    return
  fi
  if ! [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    SETUP_MSG="Rejected: only letters/digits/_/./- allowed."
    return
  fi
  SETUP_ACTIVE_FLAG="$name"
  setup_recompute_flags
  SETUP_MSG="Created flag '$name'. Press Space on each channel you want to include."
}

setup_toggle_current() {
  if [[ -z "$SETUP_ACTIVE_FLAG" ]]; then
    SETUP_MSG="No active flag. Press n to create one first."
    return
  fi
  toggle_row_flag "$SETUP_CURSOR" "$SETUP_ACTIVE_FLAG"
  setup_recompute_flags
  SETUP_MSG=""
}

setup_save() {
  local n=${#SETUP_IDS[@]} i
  local map_json='{"channel_flags":{}}'
  for (( i=0; i<n; i++ )); do
    local id="${SETUP_IDS[$i]}"
    local rf="${SETUP_ROW_FLAGS[$i]:-}"
    local arr='[]' f
    if [[ -n "$rf" ]]; then
      IFS=',' read -ra parts <<<"$rf"
      for f in "${parts[@]}"; do
        f="${f#"${f%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        [[ -z "$f" ]] && continue
        arr=$(jq -cn --argjson a "$arr" --arg f "$f" '$a + [$f]')
      done
    fi
    if [[ "$arr" != "[]" ]]; then
      map_json=$(jq -cn --argjson m "$map_json" --arg id "$id" --argjson a "$arr" \
        '$m | .channel_flags[$id] = $a')
    fi
  done
  save_flag_map "$map_json"
  FLAG_MAP_JSON="$map_json"
}

cmd_setup() {
  ensure_valid_tokens
  echo "Fetching channels..."
  fetch_channels

  local sorted
  sorted=$(printf '%s' "$CHANNELS_JSON" | jq -c 'sort_by(.displayName // "" | ascii_downcase)')
  local n
  n=$(printf '%s' "$sorted" | jq 'length')

  SETUP_NAMES=()
  SETUP_IDS=()
  SETUP_PLATFORMS=()
  SETUP_ACTIVE=()
  SETUP_ROW_FLAGS=()

  # Single jq pass, TSV-formatted
  while IFS=$'\t' read -r id name plat active; do
    SETUP_IDS+=("$id")
    SETUP_NAMES+=("${name:-(unnamed)}")
    SETUP_PLATFORMS+=("$plat")
    SETUP_ACTIVE+=("$active")
    SETUP_ROW_FLAGS+=("")
  done < <(printf '%s' "$sorted" | jq -r '.[] |
    [(.id|tostring),
     (.displayName // "(unnamed)"),
     ((.streamingPlatformId // .platformId // "")|tostring),
     (.active // false | tostring)] | @tsv')

  if load_flag_map; then
    local i
    for (( i=0; i<${#SETUP_IDS[@]}; i++ )); do
      local id="${SETUP_IDS[$i]}"
      local existing
      existing=$(printf '%s' "$FLAG_MAP_JSON" \
        | jq -r --arg id "$id" '(.channel_flags[$id] // []) | join(", ")')
      SETUP_ROW_FLAGS[$i]="$existing"
    done
  fi

  setup_recompute_flags
  SETUP_CURSOR=0
  SETUP_TOP=0
  SETUP_MSG=""

  if (( ${#SETUP_NAMES[@]} == 0 )); then
    echo "No channels found on your Restream account. Add some at restream.io first." >&2
    return "$EXIT_NO_MATCH"
  fi

  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  stty -echo 2>/dev/null || true
  trap tui_cleanup EXIT INT TERM

  n=${#SETUP_NAMES[@]}
  # Bash 3.2 (stock macOS) doesn't accept fractional `read -t` values.
  # Bash 4+ does. Pick the smallest valid timeout per version. For arrow-key
  # sequences (\e[A etc) we only need a brief pause so we don't hang on a
  # bare Esc press.
  local esc_timeout=1
  if [[ ${BASH_VERSINFO[0]:-3} -ge 4 ]]; then
    esc_timeout="0.05"
  fi
  local key c2 c3
  while :; do
    tui_draw
    IFS= read -rsn1 key || break
    case "$key" in
      $'\e')
        c2=""
        IFS= read -rsn1 -t "$esc_timeout" c2 || c2=""
        if [[ -z "$c2" ]]; then
          tui_cleanup
          trap - EXIT INT TERM
          echo "Setup cancelled. No changes saved."
          return "$EXIT_OK"
        fi
        if [[ "$c2" == "[" || "$c2" == "O" ]]; then
          c3=""
          IFS= read -rsn1 -t "$esc_timeout" c3 || c3=""
          case "$c3" in
            A) (( SETUP_CURSOR > 0 )) && SETUP_CURSOR=$((SETUP_CURSOR - 1)); SETUP_MSG="" ;;
            B) (( SETUP_CURSOR < n - 1 )) && SETUP_CURSOR=$((SETUP_CURSOR + 1)); SETUP_MSG="" ;;
            *) : ;;
          esac
        fi
        ;;
      k) (( SETUP_CURSOR > 0 )) && SETUP_CURSOR=$((SETUP_CURSOR - 1)); SETUP_MSG="" ;;
      j) (( SETUP_CURSOR < n - 1 )) && SETUP_CURSOR=$((SETUP_CURSOR + 1)); SETUP_MSG="" ;;
      g) SETUP_CURSOR=0; SETUP_MSG="" ;;
      G) SETUP_CURSOR=$(( n - 1 )); SETUP_MSG="" ;;
      ' ') setup_toggle_current ;;
      $'\t') setup_cycle_active_flag; SETUP_MSG="" ;;
      n|N) setup_new_flag ;;
      d|D) setup_delete_active_flag ;;
      s|S|q|Q)
        setup_save
        tui_cleanup
        trap - EXIT INT TERM
        local total_flags=${#SETUP_FLAGS[@]}
        local total_mapped
        total_mapped=$(printf '%s' "$FLAG_MAP_JSON" | jq '[.channel_flags | to_entries[] | select(.value | length > 0)] | length')
        echo "Saved: $total_flags flag(s) across $total_mapped channel(s)."
        echo "Run '--flags' to list them, '--flag <name>' to apply."
        log_event action setup result ok flags "$total_flags"
        return "$EXIT_OK"
        ;;
      *) : ;;
    esac
  done

  tui_cleanup
  trap - EXIT INT TERM
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
print_help() {
  cat <<'EOF'
restream-channel-switch — toggle Restream streaming destinations via the Restream API.

Usage:
  restream-channel-switch --auth
  restream-channel-switch --setup
  restream-channel-switch --list
  restream-channel-switch --flags
  restream-channel-switch --flag NAME [--dry-run]
  restream-channel-switch --enable NAME [--enable NAME ...] [--disable NAME ...]
  restream-channel-switch --status
  restream-channel-switch --reset-creds
  restream-channel-switch --help

Options:
  --auth              Run OAuth flow; store client creds + tokens in Keychain.
  --setup             Interactive TUI: assign channels to flags. Run once
                      (and whenever you add/remove Restream channels).
  --list              List channels with current active state.
  --flags             List all defined flags and channel counts.
  --flag NAME         Enable every channel tagged with flag NAME; disable the rest.
  --dry-run           With --flag: preview changes without applying.
  --enable NAME       Enable a single channel by name (repeatable).
  --disable NAME      Disable a single channel by name (repeatable).
  --status            Show user profile + last toggle + current state.
  --reset-creds       Delete stored client credentials, tokens, last state, and flag map.
  --help, -h          Show this help.

Exit codes:
  0 success, 1 auth error, 2 network/API error,
  3 flag didn't match any channels, 4 partial success,
  5 no flag mapping yet (run --setup).
EOF
}

main() {
  local do_auth=0 do_setup=0 do_list=0 do_flags=0 do_status=0 do_reset=0
  local flag="" dry=0
  local enable_list="" disable_list=""

  while (( $# > 0 )); do
    case "$1" in
      --auth)         do_auth=1 ;;
      --setup)        do_setup=1 ;;
      --list)         do_list=1 ;;
      --flags)        do_flags=1 ;;
      --status)       do_status=1 ;;
      --reset-creds)  do_reset=1 ;;
      --dry-run)      dry=1 ;;
      --flag)         flag="${2-}"; shift ;;
      --flag=*)       flag="${1#*=}" ;;
      --profile|--profile=*)
        echo "error: --profile was removed. Use --flag <name> instead (see --setup)." >&2
        return 2 ;;
      --enable)       enable_list+="${2-}"$'\n'; shift ;;
      --enable=*)     enable_list+="${1#*=}"$'\n' ;;
      --disable)      disable_list+="${2-}"$'\n'; shift ;;
      --disable=*)    disable_list+="${1#*=}"$'\n' ;;
      -h|--help)      print_help; return 0 ;;
      *)              echo "unknown argument: $1" >&2; print_help >&2; return 2 ;;
    esac
    shift
  done

  if (( do_reset )); then
    kc_delete "$KC_ACCOUNT_TOKENS"
    kc_delete "$KC_ACCOUNT_CLIENT"
    kc_delete "$KC_ACCOUNT_STATE"
    kc_delete "$KC_ACCOUNT_FLAGS"
    echo "Cleared keychain entries for $KEYCHAIN_SERVICE."
    return "$EXIT_OK"
  fi

  if (( do_auth )); then
    do_auth_flow
    return "$EXIT_OK"
  fi

  if (( do_setup )); then
    cmd_setup
    return $?
  fi

  ensure_valid_tokens

  if (( do_status )); then
    cmd_status
    return "$EXIT_OK"
  fi
  if (( do_list )); then
    cmd_list
    return "$EXIT_OK"
  fi
  if (( do_flags )); then
    cmd_flags
    return $?
  fi
  if [[ -n "$flag" ]]; then
    cmd_flag "$flag" "$dry"
    return $?
  fi
  if [[ -n "$enable_list" || -n "$disable_list" ]]; then
    cmd_enable_disable "${enable_list%$'\n'}" "${disable_list%$'\n'}"
    return $?
  fi

  print_help
  return "$EXIT_OK"
}

main "$@"
