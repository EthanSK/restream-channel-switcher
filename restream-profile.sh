#!/usr/bin/env bash
# restream-profile — toggle Restream streaming destinations on/off via the Restream API.
#
# Pure bash. Requires: curl, security (macOS), jq.
#
# Usage:
#   restream-profile --auth
#   restream-profile --list
#   restream-profile --profile wreathen [--dry-run]
#   restream-profile --enable "YouTube" --disable "Twitch"
#   restream-profile --status
#   restream-profile --reset-creds
#   restream-profile --help
#
# Tokens + client credentials live in macOS Keychain (service=com.restream-profile).
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
KEYCHAIN_SERVICE="com.restream-profile"
KC_ACCOUNT_TOKENS="tokens"
KC_ACCOUNT_CLIENT="client"
KC_ACCOUNT_STATE="last-state"

AUTHORIZE_URL="https://api.restream.io/login"
TOKEN_URL="https://api.restream.io/oauth/token"
API_BASE="https://api.restream.io/v2"

REDIRECT_PORT=8976
REDIRECT_URI="http://localhost:${REDIRECT_PORT}/callback"
SCOPES="profile.read channels.read channels.write"

LOG_DIR="${HOME}/Library/Logs/restream-profile"
LOG_FILE="${LOG_DIR}/toggle.log"
LOG_MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB

USER_AGENT="restream-profile/1.0 (+https://github.com/EthanSK/restream-profile-switcher)"

EXIT_OK=0
EXIT_AUTH=1
EXIT_NETWORK=2
EXIT_NO_MATCH=3
EXIT_PARTIAL=4

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
  # $1 = JSON blob
  kc_set "$KC_ACCOUNT_STATE" "$1"
}

load_last_state() {
  kc_get "$KC_ACCOUNT_STATE"
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
  # Minimal URL-encoder using jq.
  jq -rn --arg s "$1" '$s|@uri'
}

gen_state() {
  # 24 random bytes -> base64url
  openssl rand 24 | base64 | tr '+/' '-_' | tr -d '=\n'
}

# Start a one-shot HTTP listener with `nc`, returns the captured "code" and "state"
# via globals CB_CODE / CB_STATE / CB_ERROR.
CB_CODE=""
CB_STATE=""
CB_ERROR=""

await_oauth_callback() {
  local tmp
  tmp=$(mktemp -t restream-cb.XXXXXX)
  trap 'rm -f "$tmp"' RETURN

  # nc -l on macOS accepts GET, writes request line + headers to stdout.
  # We reply with a tiny HTML page and capture the request line.
  # Use a 300-second idle timeout.
  {
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: text/html; charset=utf-8\r\n'
    printf 'Connection: close\r\n'
    printf 'Content-Length: 94\r\n'
    printf '\r\n'
    printf '<html><body><h3>Authorization captured. You can close this tab.</h3></body></html>'
  } | nc -l "$REDIRECT_PORT" > "$tmp" 2>/dev/null || true

  # Parse first line:  GET /callback?code=...&state=... HTTP/1.1
  local req_line query
  req_line=$(head -n1 "$tmp" | tr -d '\r')
  query="${req_line#GET }"
  query="${query%% HTTP/*}"
  # strip path
  query="${query#*\?}"
  # parse
  local pair key val
  while IFS='&' read -ra pairs <<<"$query"; do
    for pair in "${pairs[@]}"; do
      key="${pair%%=*}"
      val="${pair#*=}"
      # URL-decode
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

  # Start listener in background, then open browser.
  await_oauth_callback &
  local cb_pid=$!
  # Give nc a moment to bind
  sleep 0.3
  open "$auth_url" 2>/dev/null || true

  # Wait up to 300s
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
  log_event action auth result ok
}

# ---------------------------------------------------------------------------
# Token exchange / refresh
# ---------------------------------------------------------------------------
# On success, updates globals + keychain.
_token_post() {
  # $@ = extra curl form fields (-d ...)
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
  # $1 = code
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
# Sets API_STATUS + API_BODY globals. Auto-retries once on 401 (refresh+retry).
API_STATUS=0
API_BODY=""

api_call() {
  # $1 = method, $2 = path (no base), $3 = optional JSON body
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
  # $1 = id, $2 = true|false
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
# Profile logic
# ---------------------------------------------------------------------------
# Returns (via stdout) a JSON array of channels whose displayName contains $2 (case-insensitive).
match_channels() {
  # $1=channels_json, $2=needle
  printf '%s' "$1" | jq --arg n "$2" '
    [.[] | select((.displayName // "" | ascii_downcase) | contains($n | ascii_downcase))]
  '
}

# Find exactly one channel matching $2 (exact, then unique substring).
# Prints the channel object as JSON, or empty; exits via return value: 0 found, 1 none, 2 ambiguous.
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

# Apply a set of enable/disable ops. Populates ENABLED_NAMES / DISABLED_NAMES / ERRORS_JSON.
ENABLED_NAMES=()
DISABLED_NAMES=()
ERRORS_JSON="[]"

apply_toggles() {
  # $1 = JSON array of channels to enable
  # $2 = JSON array of channels to disable
  ENABLED_NAMES=()
  DISABLED_NAMES=()
  ERRORS_JSON="[]"

  local id name
  # enable loop
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

  # disable loop
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

cmd_profile() {
  local profile="$1" dry="$2"
  fetch_channels

  local matches to_enable to_disable
  matches=$(match_channels "$CHANNELS_JSON" "$profile")
  local match_count
  match_count=$(printf '%s' "$matches" | jq 'length')
  if (( match_count == 0 )); then
    echo "No channels match profile '$profile'." >&2
    log_event action profile profile "$profile" result no-match
    return "$EXIT_NO_MATCH"
  fi

  # to_enable = matches that are not yet active
  to_enable=$(printf '%s' "$matches" | jq '[.[] | select(.active | not)]')
  # to_disable = all non-matching channels currently active
  to_disable=$(jq -cn --argjson all "$CHANNELS_JSON" --argjson m "$matches" '
    ($m | map(.id)) as $keep
    | [$all[] | select(.active and ((.id as $id | $keep | index($id)) | not))]
  ')

  local en_count dis_count
  en_count=$(printf '%s' "$to_enable" | jq 'length')
  dis_count=$(printf '%s' "$to_disable" | jq 'length')

  echo "Profile '$profile':"
  echo "  matches ($match_count):  $(printf '%s' "$matches" | jq -c '[.[].displayName]')"
  echo "  will enable  ($en_count): $(printf '%s' "$to_enable" | jq -c '[.[].displayName]')"
  echo "  will disable ($dis_count): $(printf '%s' "$to_disable" | jq -c '[.[].displayName]')"

  if [[ "$dry" == "1" ]]; then
    echo "(dry-run; no changes)"
    return "$EXIT_OK"
  fi

  apply_toggles "$to_enable" "$to_disable"

  local ts state_json
  ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
  state_json=$(jq -cn \
    --arg profile "$profile" --arg ts "$ts" \
    --argjson enabled "$(printf '%s\n' "${ENABLED_NAMES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    --argjson disabled "$(printf '%s\n' "${DISABLED_NAMES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    --argjson errors "$ERRORS_JSON" \
    '{profile:$profile, ts:$ts, enabled:$enabled, disabled:$disabled, errors:$errors}')
  save_last_state "$state_json"

  local err_count
  err_count=$(printf '%s' "$ERRORS_JSON" | jq 'length')
  local result="ok"
  (( err_count > 0 )) && result="partial"
  log_event action profile profile "$profile" result "$result" errors "$err_count"

  if (( err_count > 0 )); then
    echo
    echo "$err_count error(s) during toggle." >&2
    return "$EXIT_PARTIAL"
  fi
  echo
  echo "Profile '$profile' applied."
  return "$EXIT_OK"
}

cmd_enable_disable() {
  # $1 = newline-separated enable names, $2 = newline-separated disable names
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
  local last
  last=$(load_last_state) || last=""
  if [[ -n "$last" ]]; then
    echo
    echo "Last toggle:"
    printf '  ts:       %s\n' "$(printf '%s' "$last" | jq -r '.ts // ""')"
    printf '  profile:  %s\n' "$(printf '%s' "$last" | jq -r '.profile // ""')"
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
# CLI
# ---------------------------------------------------------------------------
print_help() {
  cat <<'EOF'
restream-profile — toggle Restream streaming destinations via the Restream API.

Usage:
  restream-profile --auth
  restream-profile --list
  restream-profile --profile NAME [--dry-run]
  restream-profile --enable NAME [--enable NAME ...] [--disable NAME ...]
  restream-profile --status
  restream-profile --reset-creds
  restream-profile --help

Options:
  --auth              Run OAuth flow; store client creds + tokens in Keychain.
  --list              List channels with current active state.
  --profile NAME      Enable channels whose displayName contains NAME
                      (case-insensitive substring); disable all others.
  --dry-run           With --profile: preview changes without applying.
  --enable NAME       Enable a single channel by name (repeatable).
  --disable NAME      Disable a single channel by name (repeatable).
  --status            Show user profile + last toggle + current state.
  --reset-creds       Delete stored client credentials, tokens, and last state.
  --help, -h          Show this help.

Exit codes:
  0 success, 1 auth error, 2 network/API error,
  3 profile didn't match, 4 partial success.
EOF
}

main() {
  local do_auth=0 do_list=0 do_status=0 do_reset=0
  local profile="" dry=0
  local enable_list="" disable_list=""

  while (( $# > 0 )); do
    case "$1" in
      --auth)         do_auth=1 ;;
      --list)         do_list=1 ;;
      --status)       do_status=1 ;;
      --reset-creds)  do_reset=1 ;;
      --dry-run)      dry=1 ;;
      --profile)      profile="${2-}"; shift ;;
      --profile=*)    profile="${1#*=}" ;;
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
    echo "Cleared keychain entries for $KEYCHAIN_SERVICE."
    return "$EXIT_OK"
  fi

  if (( do_auth )); then
    do_auth_flow
    return "$EXIT_OK"
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
  if [[ -n "$profile" ]]; then
    cmd_profile "$profile" "$dry"
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
