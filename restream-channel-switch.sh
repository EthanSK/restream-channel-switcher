#!/usr/bin/env bash
# restream-channel-switch — toggle Restream streaming destinations on/off
# based on user-defined "aliases" (labels) that map to explicit sets of
# channels by channel ID.
#
# Pure bash. Requires: bash 3.2+, curl, jq, security (macOS), nc, openssl, open.
#
# Usage:
#   restream-channel-switch --auth
#   restream-channel-switch --setup
#   restream-channel-switch --add-alias NAME
#   restream-channel-switch --list
#   restream-channel-switch --aliases
#   restream-channel-switch --alias NAME [--dry-run]
#   restream-channel-switch --status
#   restream-channel-switch --reset-creds
#   restream-channel-switch --help
#
# Tokens + client credentials + alias map live in the macOS Keychain.
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
KC_ACCOUNT_ALIASES="channel-aliases"
KC_ACCOUNT_ALIASES_LEGACY="channel-flags"

AUTHORIZE_URL="https://api.restream.io/login"
TOKEN_URL="https://api.restream.io/oauth/token"
API_BASE="https://api.restream.io/v2"

REDIRECT_PORT=8976
REDIRECT_URI="http://localhost:${REDIRECT_PORT}/callback"
SCOPES="profile.read channels.read channels.write"

LOG_DIR="${HOME}/Library/Logs/restream-channel-switch"
LOG_FILE="${LOG_DIR}/toggle.log"
LOG_MAX_BYTES=$((10 * 1024 * 1024))  # 10 MB

USER_AGENT="restream-channel-switch/2.1 (+https://github.com/EthanSK/restream-channel-switcher)"

# ---------------------------------------------------------------------------
# Platform-name derivation (jq fragment, shared between cmd_list and picker)
# ---------------------------------------------------------------------------
# Restream supports 30+ destinations. We resolve a friendly platform name
# from (in order): URL hostname regex → identifier-prefix heuristic →
# numeric streamingPlatformId lookup → fallback "plat-<id>".
#
# streamingPlatformId integers were derived from:
#   - Empirical channel data on Ethan's account (1, 5, 37, 57, 67, 68, 71, 75)
#   - https://support.restream.io/en/articles/872029-supported-social-platforms
#     (canonical list of 30+ supported destinations, fetched 2026-04)
#   - https://restream.io/integrations/ (also lists Vimeo, Telegram, Substack)
#
# IDs we have NOT empirically verified are intentionally omitted from the
# integer-lookup branch (URL/hostname regex catches them anyway when present).
# Restream exposes no public /platforms endpoint as of 2026-04 (404 on every
# reasonable path tried with a valid bearer token), so this list is hardcoded.
PLATFORM_NAME_JQ='
def platform_name:
  ((.url // "") | ascii_downcase) as $u |
  ((.identifier // "") | ascii_downcase) as $idf |
  if   ($u | test("youtube\\.com|youtu\\.be"))                 then "YouTube"
  elif ($u | test("twitch\\.tv"))                              then "Twitch"
  elif ($u | test("kick\\.com"))                               then "Kick"
  elif ($u | test("rumble\\.com"))                             then "Rumble"
  elif ($u | test("facebook\\.com|fb\\.com|fb\\.gg"))          then "Facebook"
  elif ($u | test("linkedin\\.com|lnkd\\.in"))                 then "LinkedIn"
  elif ($u | test("mixcloud\\.com"))                           then "Mixcloud"
  elif ($u | test("dlive\\.tv"))                               then "DLive"
  elif ($u | test("trovo\\.live"))                             then "Trovo"
  elif ($u | test("tiktok\\.com"))                             then "TikTok"
  elif ($u | test("instagram\\.com"))                          then "Instagram"
  elif ($u | test("(^|[./])((x|twitter)\\.com|t\\.co)([/:?#]|$)")) then "X"
  elif ($u | test("vimeo\\.com"))                              then "Vimeo"
  elif ($u | test("dailymotion\\.com|dai\\.ly"))               then "Dailymotion"
  elif ($u | test("amazon\\.com/live|live\\.amazon\\.com"))    then "Amazon Live"
  elif ($u | test("steamcommunity\\.com|store\\.steampowered\\.com|steam\\.tv")) then "Steam"
  elif ($u | test("picarto\\.tv"))                             then "Picarto"
  elif ($u | test("vaughn\\.live|vaughnlive\\.tv"))            then "Vaughn Live"
  elif ($u | test("bilibili\\.com|live\\.bilibili"))           then "Bilibili"
  elif ($u | test("douyu\\.com"))                              then "Douyu"
  elif ($u | test("huya\\.com"))                               then "Huya"
  elif ($u | test("nimo\\.tv"))                                then "Nimo TV"
  elif ($u | test("nonolive\\.com"))                           then "Nonolive"
  elif ($u | test("naver\\.com|navertv\\.com|tv\\.naver"))     then "Naver TV"
  elif ($u | test("kakao\\.com|tv\\.kakao"))                   then "KakaoTV"
  elif ($u | test("zhanqi\\.tv"))                              then "Zhanqi"
  elif ($u | test("fc2\\.com"))                                then "FC2 Live"
  elif ($u | test("breakers\\.tv"))                            then "Breakers.TV"
  elif ($u | test("majorleaguegaming\\.com|mlg\\.com"))        then "MLG"
  elif ($u | test("soop\\.live|sooplive|afreecatv\\.com"))     then "SOOP"
  elif ($u | test("substack\\.com"))                           then "Substack"
  elif ($u | test("t\\.me|telegram\\.(me|org)"))               then "Telegram"
  elif ($u | test("mux\\.com"))                                then "Mux"
  elif ($idf | startswith("dlive-"))                           then "DLive"
  else (.streamingPlatformId // .platformId // 0) as $pid
       | (if   $pid == 1  then "Twitch"
          elif $pid == 5  then "YouTube"
          elif $pid == 37 then "Facebook"
          elif $pid == 57 then "DLive"
          elif $pid == 67 then "TikTok"
          elif $pid == 68 then "Mixcloud"
          elif $pid == 71 then "X"
          elif $pid == 75 then "Kick"
          else "plat-" + ($pid | tostring)
          end)
  end;
'

EXIT_OK=0
EXIT_AUTH=1
EXIT_NETWORK=2
EXIT_NO_MATCH=3
EXIT_PARTIAL=4
EXIT_NO_SETUP=5

# After applying an alias, re-fetch Restream's channel list and verify the
# actual active state. If Restream accepted only some PATCHes, re-apply just
# the mismatched channels this many times before returning partial failure.
VERIFY_RETRIES_DEFAULT=2
VERIFY_SLEEP_SECONDS_DEFAULT=1

# Network-level retry for transient connection failures (DNS resolution
# failure, connection refused, TLS hiccup). Especially relevant when
# fired from a USB-plug-in / wake-from-sleep trigger where the network
# stack may not be ready yet. Backoff is exponential: SLEEP_SECONDS,
# 2*SLEEP_SECONDS, 4*SLEEP_SECONDS, ... capped at BACKOFF_CAP_SECONDS so
# individual sleeps don't balloon to multi-minute waits.
#
# Retries continue until EITHER the call succeeds, OR total elapsed time
# since the first attempt exceeds NET_TOTAL_TIMEOUT_SECONDS, OR the
# RESTREAM_NET_RETRIES cap is hit (whichever comes first). The total-
# timeout default of 1800s (30 min) handles slow Wi-Fi recovery on USB
# plug-in / wake-from-sleep — the script self-heals once the network
# stack comes back, instead of failing fast at ~30s.
#
# These ONLY apply to network-level failures (curl exit non-zero, or
# HTTP status "000"). Auth errors (4xx) and server errors (5xx) are NOT
# retried by this layer — those are application-level and need their
# own handling (e.g. /user/channel returning 401 triggers a refresh in
# api_call, refresh token rotation is handled by save_tokens, etc.).
NET_RETRIES_DEFAULT=10000
NET_SLEEP_SECONDS_DEFAULT=2
NET_TIMEOUT_SECONDS_DEFAULT=15
NET_TOTAL_TIMEOUT_SECONDS_DEFAULT=1800
NET_BACKOFF_CAP_SECONDS_DEFAULT=120

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
ALIAS_MAP_JSON=""

alias_map_is_valid() {
  printf '%s' "$1" | jq -e '
    type == "object"
    and (.channel_aliases | type == "object")
    and ((.channel_aliases // {}) | all(.[]; type == "array" and all(.[]; type == "string")))
  ' >/dev/null 2>&1
}

legacy_alias_map_is_valid() {
  printf '%s' "$1" | jq -e '
    type == "object"
    and (.channel_flags | type == "object")
    and ((.channel_flags // {}) | all(.[]; type == "array" and all(.[]; type == "string")))
  ' >/dev/null 2>&1
}

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

# Load alias map. Schema:
#   {"channel_aliases": {"<channel_id>": ["alias1", "alias2"], ...}}
#
# One-time migration: if the new key is missing but the legacy
# "channel-flags" key exists with a "channel_flags" object, read it,
# rename the wrapping key to "channel_aliases", save under the new
# keychain account, and use it. Legacy entry is left in place (we don't
# delete it) so a downgrade still works during the transition; --reset-creds
# does clear both.
load_alias_map() {
  local raw
  raw=$(kc_get "$KC_ACCOUNT_ALIASES" 2>/dev/null || true)
  if [[ -n "$raw" ]]; then
    if alias_map_is_valid "$raw"; then
      ALIAS_MAP_JSON="$raw"
      return 0
    fi
    echo "error: keychain entry '$KC_ACCOUNT_ALIASES' is not a valid alias map; refusing to overwrite it." >&2
    return 2
  fi

  # Legacy fallback: read "channel-flags" → migrate to "channel-aliases".
  local legacy
  legacy=$(kc_get "$KC_ACCOUNT_ALIASES_LEGACY" 2>/dev/null || true)
  if [[ -n "$legacy" ]] && legacy_alias_map_is_valid "$legacy"; then
    local migrated
    migrated=$(printf '%s' "$legacy" | jq -c '{channel_aliases: (.channel_flags // {})}') || return 1
    if ! save_alias_map "$migrated"; then
      echo "error: failed to save migrated alias map to keychain account '$KC_ACCOUNT_ALIASES'." >&2
      return 2
    fi
    ALIAS_MAP_JSON="$migrated"
    echo "(migrated legacy 'channel-flags' keychain entry → 'channel-aliases')" >&2
    log_event action migrate from channel-flags to channel-aliases result ok
    return 0
  fi

  return 1
}

save_alias_map() {
  kc_set "$KC_ACCOUNT_ALIASES" "$1"
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
  # $1 = path of result file to write CB_CODE/CB_STATE/CB_ERROR into.
  # Required because this function is invoked via `&`, which puts it in a
  # subshell — globals set here would not propagate to the parent.
  local result_file="$1"
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

  printf 'CB_CODE=%q\nCB_STATE=%q\nCB_ERROR=%q\n' \
    "$CB_CODE" "$CB_STATE" "$CB_ERROR" > "$result_file"
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

  local cb_result
  cb_result=$(mktemp -t restream-cb-result.XXXXXX)
  trap 'rm -f "$cb_result"' RETURN

  await_oauth_callback "$cb_result" &
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

  # Pull captured values from the result file (the subshell can't write to
  # parent globals via `func &`, so we round-trip through a temp file).
  if [[ -s "$cb_result" ]]; then
    # shellcheck disable=SC1090
    source "$cb_result"
  fi

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
  echo "Next: run '--setup' to map your channels to aliases."
  log_event action auth result ok
}

# ---------------------------------------------------------------------------
# Network retry helper
# ---------------------------------------------------------------------------
# Run a curl-based command with retry on network-level failures (DNS
# resolution failure, connection refused, TLS handshake, etc. — anything
# that produces a non-zero curl exit OR an HTTP status of "000").
#
# This is critical when the script is fired by an OBScene USB-plug-in /
# display-attach trigger right after wake-from-sleep — the network stack
# is often still coming up at that exact moment, and a one-shot curl
# silently fails with "Could not resolve host" (status code 000), causing
# the whole channel-switch to no-op while looking like it succeeded.
# (Pre-2026-05-10 silent-failure mode.)
#
# Caller passes the curl invocation as a function name + args. The function
# is expected to:
#   - on success: set status/body globals (or whatever its contract is) and
#     return 0.
#   - on transient network failure: print to stderr and return 1.
#   - on auth/app failure: return 1 (we cannot distinguish here, so the
#     caller is responsible for not retrying app-level errors via this
#     helper — see _token_post which only invokes us for the curl portion).
#
# Public globals consumed:
#   RESTREAM_NET_RETRIES              — override NET_RETRIES_DEFAULT
#                                       (hard cap on attempt count; default
#                                       is effectively unbounded so the
#                                       total-timeout is the gate)
#   RESTREAM_NET_SLEEP_SECONDS        — override NET_SLEEP_SECONDS_DEFAULT
#                                       (initial backoff seconds)
#   RESTREAM_NET_TOTAL_TIMEOUT_SECONDS — override NET_TOTAL_TIMEOUT_SECONDS_DEFAULT
#                                       (upper bound on TOTAL elapsed retry time)
#   RESTREAM_NET_BACKOFF_CAP_SECONDS  — override NET_BACKOFF_CAP_SECONDS_DEFAULT
#                                       (cap on individual sleep durations)
NET_LAST_ATTEMPTS=0
with_net_retry() {
  local label="$1"
  shift
  local max_retries sleep_seconds total_timeout backoff_cap attempt rc
  max_retries=$(positive_int_or_default "${RESTREAM_NET_RETRIES:-}" "$NET_RETRIES_DEFAULT")
  sleep_seconds=$(positive_int_or_default "${RESTREAM_NET_SLEEP_SECONDS:-}" "$NET_SLEEP_SECONDS_DEFAULT")
  total_timeout=$(positive_int_or_default "${RESTREAM_NET_TOTAL_TIMEOUT_SECONDS:-}" "$NET_TOTAL_TIMEOUT_SECONDS_DEFAULT")
  backoff_cap=$(positive_int_or_default "${RESTREAM_NET_BACKOFF_CAP_SECONDS:-}" "$NET_BACKOFF_CAP_SECONDS_DEFAULT")
  NET_LAST_ATTEMPTS=0

  local start now elapsed backoff sleep_for
  start=$(date +%s)
  for (( attempt=0; attempt<=max_retries; attempt++ )); do
    NET_LAST_ATTEMPTS=$((attempt + 1))
    "$@"
    rc=$?
    now=$(date +%s)
    elapsed=$(( now - start ))
    if (( rc == 0 )); then
      if (( attempt > 0 )); then
        log_event action net-retry-recovered label "$label" attempts "$NET_LAST_ATTEMPTS" elapsed_s "$elapsed"
      fi
      return 0
    fi
    # Compute next backoff: 2^attempt * sleep_seconds, capped.
    backoff=$(( sleep_seconds * (1 << attempt) ))
    if (( backoff > backoff_cap )); then
      backoff="$backoff_cap"
    fi
    sleep_for="$backoff"
    # Stop if we've exhausted the attempt cap, or the next sleep would
    # push us past the total timeout. Sleeping right up to the cap is
    # fine; sleeping past it just wastes wall time.
    if (( attempt >= max_retries )) || (( elapsed + sleep_for >= total_timeout )); then
      log_event action net-retry-exhausted label "$label" attempts "$NET_LAST_ATTEMPTS" elapsed_s "$elapsed" total_timeout_s "$total_timeout"
      return "$rc"
    fi
    log_event action net-retry-attempt label "$label" attempt "$NET_LAST_ATTEMPTS" elapsed_s "$elapsed" sleep_s "$sleep_for"
    echo "  network failure for $label (attempt $NET_LAST_ATTEMPTS, elapsed ${elapsed}s/${total_timeout}s); retrying in ${sleep_for}s..." >&2
    sleep "$sleep_for"
  done
  return 1
}

# ---------------------------------------------------------------------------
# Token exchange / refresh
# ---------------------------------------------------------------------------
TOKEN_POST_STATUS=0
TOKEN_POST_BODY=""
TOKEN_POST_CURL_EXIT=0

# Inner curl call for _token_post. Sets TOKEN_POST_* globals.
# Returns:
#   0 — got an HTTP response, even a non-2xx one (auth error, etc.)
#   1 — transient network failure (curl non-zero, or HTTP "000" / no response)
_token_post_curl() {
  local timeout_seconds
  timeout_seconds=$(positive_int_or_default "${RESTREAM_NET_TIMEOUT_SECONDS:-}" "$NET_TIMEOUT_SECONDS_DEFAULT")
  local resp curl_exit
  resp=$(curl -sS -w $'\n%{http_code}' \
    --connect-timeout "$timeout_seconds" \
    --max-time $(( timeout_seconds * 2 )) \
    -u "${CLIENT_ID}:${CLIENT_SECRET}" \
    -H "User-Agent: $USER_AGENT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    "${_TOKEN_POST_ARGS[@]}" \
    "$TOKEN_URL" 2>&1)
  curl_exit=$?
  TOKEN_POST_CURL_EXIT="$curl_exit"
  TOKEN_POST_STATUS="${resp##*$'\n'}"
  TOKEN_POST_BODY="${resp%$'\n'*}"
  if (( curl_exit != 0 )) || [[ "$TOKEN_POST_STATUS" == "000" ]]; then
    echo "token request: curl exit=$curl_exit status=$TOKEN_POST_STATUS body=$TOKEN_POST_BODY" >&2
    return 1
  fi
  return 0
}

_token_post() {
  # Capture caller-supplied curl args into a global so the inner curl
  # function (invoked via with_net_retry) can see them — bash doesn't
  # let us pass arrays through "$@" composition cleanly here.
  _TOKEN_POST_ARGS=("$@")
  if ! with_net_retry token_post _token_post_curl; then
    log_event action token-post-net-fail attempts "$NET_LAST_ATTEMPTS" curl_exit "$TOKEN_POST_CURL_EXIT" status "$TOKEN_POST_STATUS"
    echo "token request failed after $NET_LAST_ATTEMPTS attempt(s) (curl exit $TOKEN_POST_CURL_EXIT)." >&2
    return 1
  fi
  if [[ "$TOKEN_POST_STATUS" != "200" ]]; then
    echo "token request failed ($TOKEN_POST_STATUS): $TOKEN_POST_BODY" >&2
    log_event action token-post-http-fail status "$TOKEN_POST_STATUS"
    return 1
  fi
  local access refresh expires_in now expires_at
  access=$(printf '%s' "$TOKEN_POST_BODY" | jq -r '.access_token // .accessToken // empty')
  refresh=$(printf '%s' "$TOKEN_POST_BODY" | jq -r '.refresh_token // .refreshToken // empty')
  expires_in=$(printf '%s' "$TOKEN_POST_BODY" | jq -r '.expires_in // .accessTokenExpiresIn // 3600')
  if [[ -z "$access" || -z "$refresh" ]]; then
    echo "token response missing fields: $TOKEN_POST_BODY" >&2
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

_API_CALL_ARGS=()
_API_CALL_PATH=""
API_CALL_CURL_EXIT=0

# Inner curl call for api_call. Sets API_STATUS / API_BODY / API_CALL_CURL_EXIT.
# Returns:
#   0 — got an HTTP response (any status), so the caller can branch on it
#   1 — transient network failure (curl non-zero, or HTTP "000" / no response)
_api_call_curl() {
  local resp curl_exit
  resp=$(curl "${_API_CALL_ARGS[@]}" "${API_BASE}${_API_CALL_PATH}" 2>&1)
  curl_exit=$?
  API_CALL_CURL_EXIT="$curl_exit"
  API_STATUS="${resp##*$'\n'}"
  API_BODY="${resp%$'\n'*}"
  if (( curl_exit != 0 )) || [[ "$API_STATUS" == "000" ]]; then
    echo "api_call $_API_CALL_PATH: curl exit=$curl_exit status=$API_STATUS" >&2
    return 1
  fi
  return 0
}

api_call() {
  local method="$1" path="$2" body="${3-}"
  local retried=0
  local timeout_seconds
  timeout_seconds=$(positive_int_or_default "${RESTREAM_NET_TIMEOUT_SECONDS:-}" "$NET_TIMEOUT_SECONDS_DEFAULT")
  while :; do
    _API_CALL_ARGS=(-sS -X "$method" -w $'\n%{http_code}' \
      --connect-timeout "$timeout_seconds" \
      --max-time $(( timeout_seconds * 2 )) \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "User-Agent: $USER_AGENT" \
      -H "Accept: application/json")
    if [[ -n "$body" ]]; then
      _API_CALL_ARGS+=(-H "Content-Type: application/json" --data "$body")
    fi
    _API_CALL_PATH="$path"
    if ! with_net_retry "api_call $method $path" _api_call_curl; then
      log_event action api-net-fail method "$method" path "$path" attempts "$NET_LAST_ATTEMPTS" curl_exit "$API_CALL_CURL_EXIT" status "$API_STATUS"
      echo "API call $method $path failed after $NET_LAST_ATTEMPTS attempt(s) (curl exit $API_CALL_CURL_EXIT)." >&2
      # Surface as 000 so caller's status-code check still works.
      API_STATUS="000"
      return 0
    fi
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
# Toggle application
# ---------------------------------------------------------------------------
ENABLED_NAMES=()
DISABLED_NAMES=()
ERRORS_JSON="[]"
VERIFY_MISMATCHES_JSON="[]"
VERIFY_TO_ENABLE_JSON="[]"
VERIFY_TO_DISABLE_JSON="[]"

reset_toggle_results() {
  ENABLED_NAMES=()
  DISABLED_NAMES=()
  ERRORS_JSON="[]"
}

append_toggle_error() {
  local name="$1" op="$2" status="$3"
  ERRORS_JSON=$(printf '%s' "$ERRORS_JSON" | jq \
    --arg n "$name" --arg op "$op" --arg s "$status" \
    '. + [{channel:$n, op:$op, status:$s}]')
}

apply_toggles() {
  local id name
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" ]] && continue
    if set_channel_active "$id" true; then
      ENABLED_NAMES+=("$name")
      echo "  ok enabled  $name (id $id)"
    else
      echo "  FAIL enable $name (id $id): $API_STATUS $API_BODY" >&2
      append_toggle_error "$name" "enable" "$API_STATUS"
    fi
  done < <(printf '%s' "$1" | jq -r '.[] | "\(.id)\t\(.displayName)"')

  while IFS=$'\t' read -r id name; do
    [[ -z "$id" ]] && continue
    if set_channel_active "$id" false; then
      DISABLED_NAMES+=("$name")
      echo "  ok disabled $name (id $id)"
    else
      echo "  FAIL disable $name (id $id): $API_STATUS $API_BODY" >&2
      append_toggle_error "$name" "disable" "$API_STATUS"
    fi
  done < <(printf '%s' "$2" | jq -r '.[] | "\(.id)\t\(.displayName)"')
}

positive_int_or_default() {
  local value="$1" default="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

compute_verify_mismatches_for_alias() {
  local alias_name="$1" channels="$2" alias_map="$3"
  VERIFY_MISMATCHES_JSON=$(jq -cn --arg a "$alias_name" --argjson m "$alias_map" --argjson ch "$channels" '
    def live: if .enabled != null then .enabled elif .active != null then .active else false end;
    ($m.channel_aliases // {}) as $ca
    | [$ch[]
      | ((($ca[(.id|tostring)] // []) | index($a)) != null) as $expected
      | (live) as $actual
      | select($actual != $expected)
      | {id:(.id|tostring), displayName:(.displayName // (.id|tostring)), expectedActive:$expected, actualActive:$actual}]
  ')
  VERIFY_TO_ENABLE_JSON=$(printf '%s' "$VERIFY_MISMATCHES_JSON" | jq '[.[] | select(.expectedActive == true) | {id, displayName}]')
  VERIFY_TO_DISABLE_JSON=$(printf '%s' "$VERIFY_MISMATCHES_JSON" | jq '[.[] | select(.expectedActive == false) | {id, displayName}]')
}

verify_alias_state() {
  local alias_name="$1"
  fetch_channels
  compute_verify_mismatches_for_alias "$alias_name" "$CHANNELS_JSON" "$ALIAS_MAP_JSON"
  local mismatch_count
  mismatch_count=$(printf '%s' "$VERIFY_MISMATCHES_JSON" | jq 'length')
  if (( mismatch_count == 0 )); then
    echo "  verified: all channels match alias '$alias_name'"
    return 0
  fi

  echo "  verify mismatch ($mismatch_count channel(s)):" >&2
  printf '%s' "$VERIFY_MISMATCHES_JSON" | jq -r '
    .[] | "    - \(.displayName) (id \(.id)): expected=\(if .expectedActive then "ON" else "off" end), actual=\(if .actualActive then "ON" else "off" end)"
  ' >&2
  return 1
}

record_verify_mismatches_as_errors() {
  ERRORS_JSON=$(jq -cn --argjson existing "$ERRORS_JSON" --argjson mismatches "$VERIFY_MISMATCHES_JSON" '
    $existing + ($mismatches | map({
      channel:.displayName,
      op:"verify",
      status:"mismatch",
      expectedActive:.expectedActive,
      actualActive:.actualActive
    }))
  ')
}

# ---------------------------------------------------------------------------
# Alias-driven logic
# ---------------------------------------------------------------------------
TO_ENABLE_JSON="[]"
TO_DISABLE_JSON="[]"
MATCH_COUNT=0

compute_toggles_for_alias() {
  local alias_name="$1" channels="$2" alias_map="$3"
  local matched
  matched=$(jq -cn --arg a "$alias_name" --argjson m "$alias_map" --argjson ch "$channels" '
    ($m.channel_aliases // {}) as $ca
    | [$ch[] | select(
        (($ca[(.id|tostring)] // []) | index($a)) != null
      )]
  ')
  MATCH_COUNT=$(printf '%s' "$matched" | jq 'length')

  TO_ENABLE_JSON=$(printf '%s' "$matched" | jq '
    def live: if .enabled != null then .enabled elif .active != null then .active else false end;
    [.[] | select((live | not))]
  ')
  TO_DISABLE_JSON=$(jq -cn --argjson all "$channels" --argjson m "$matched" '
    def live: if .enabled != null then .enabled elif .active != null then .active else false end;
    ($m | map(.id)) as $keep
    | [$all[] | select(live and ((.id as $id | $keep | index($id)) | not))]
  ')
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_list() {
  fetch_channels
  printf '%-6s %-12s %-14s %s\n' "STATE" "ID" "PLATFORM" "NAME"
  printf '%s' "$CHANNELS_JSON" \
    | jq -r "
      def live: if .enabled != null then .enabled elif .active != null then .active else false end;
      ${PLATFORM_NAME_JQ}
      sort_by([platform_name, (.displayName // \"\" | ascii_downcase)]) | .[]
      | [(if live then \"ON \" else \"off\" end),
         (.id // \"\" | tostring),
         platform_name,
         (.displayName // \"\")] | @tsv" \
    | awk -F'\t' '{printf "%-6s %-12s %-14s %s\n", $1, $2, $3, $4}'
  local total active
  total=$(printf '%s' "$CHANNELS_JSON" | jq 'length')
  active=$(printf '%s' "$CHANNELS_JSON" | jq '
    def live: if .enabled != null then .enabled elif .active != null then .active else false end;
    [.[] | select(live)] | length')
  printf '\n%d channel(s), %d active.\n' "$total" "$active"
}

cmd_aliases() {
  local load_rc
  load_alias_map
  load_rc=$?
  if (( load_rc == 1 )); then
    echo "No alias mapping yet. Run --setup to create one." >&2
    return "$EXIT_NO_SETUP"
  elif (( load_rc != 0 )); then
    return "$EXIT_NETWORK"
  fi
  printf '%s' "$ALIAS_MAP_JSON" | jq -r '
    (.channel_aliases // {})
    | to_entries
    | map((.value // []) | unique | .[])
    | group_by(.)
    | map({alias: .[0], count: length})
    | sort_by(.alias)
    | (if length == 0 then
        "(no aliases defined yet)"
       else
        (["ALIAS","CHANNELS"] | @tsv),
        (.[] | [.alias, (.count|tostring)] | @tsv)
       end)
  ' | awk -F'\t' '{printf "%-24s %s\n", $1, $2}'
}

cmd_alias() {
  local alias_name="$1" dry="$2"
  local load_rc
  load_alias_map
  load_rc=$?
  if (( load_rc == 1 )); then
    cat >&2 <<EOF
No alias mapping found. Run '--setup' first to choose which channels
belong to which aliases. For example:

  restream-channel-switch --setup
  restream-channel-switch --alias $alias_name
EOF
    log_event action alias alias "$alias_name" result no-setup
    return "$EXIT_NO_SETUP"
  elif (( load_rc != 0 )); then
    log_event action alias alias "$alias_name" result invalid-alias-map
    return "$EXIT_NETWORK"
  fi
  fetch_channels

  compute_toggles_for_alias "$alias_name" "$CHANNELS_JSON" "$ALIAS_MAP_JSON"

  if (( MATCH_COUNT == 0 )); then
    echo "No channels are assigned to alias '$alias_name'." >&2
    echo "Run --setup to assign channels, or --aliases to list defined aliases." >&2
    log_event action alias alias "$alias_name" result no-match
    return "$EXIT_NO_MATCH"
  fi

  local en_count dis_count matched_names
  matched_names=$(jq -cn --arg a "$alias_name" --argjson m "$ALIAS_MAP_JSON" --argjson ch "$CHANNELS_JSON" '
    ($m.channel_aliases // {}) as $ca
    | [$ch[] | select((($ca[(.id|tostring)] // []) | index($a)) != null) | .displayName]
  ')
  en_count=$(printf '%s' "$TO_ENABLE_JSON" | jq 'length')
  dis_count=$(printf '%s' "$TO_DISABLE_JSON" | jq 'length')

  echo "Alias '$alias_name':"
  echo "  channels in alias ($MATCH_COUNT): $matched_names"
  echo "  will enable  ($en_count): $(printf '%s' "$TO_ENABLE_JSON" | jq -c '[.[].displayName]')"
  echo "  will disable ($dis_count): $(printf '%s' "$TO_DISABLE_JSON" | jq -c '[.[].displayName]')"

  if [[ "$dry" == "1" ]]; then
    echo "(dry-run; no changes)"
    return "$EXIT_OK"
  fi

  reset_toggle_results
  apply_toggles "$TO_ENABLE_JSON" "$TO_DISABLE_JSON"

  local max_verify_retries verify_sleep verify_attempt verified
  max_verify_retries=$(positive_int_or_default "${RESTREAM_VERIFY_RETRIES:-}" "$VERIFY_RETRIES_DEFAULT")
  verify_sleep=$(positive_int_or_default "${RESTREAM_VERIFY_SLEEP_SECONDS:-}" "$VERIFY_SLEEP_SECONDS_DEFAULT")
  verified="false"

  echo
  echo "Verifying Restream channel state..."
  for (( verify_attempt=0; verify_attempt<=max_verify_retries; verify_attempt++ )); do
    if verify_alias_state "$alias_name"; then
      verified="true"
      break
    fi
    if (( verify_attempt >= max_verify_retries )); then
      break
    fi
    echo "  re-applying mismatched channels (retry $((verify_attempt + 1))/$max_verify_retries)..." >&2
    apply_toggles "$VERIFY_TO_ENABLE_JSON" "$VERIFY_TO_DISABLE_JSON"
    sleep "$verify_sleep"
  done

  if [[ "$verified" != "true" ]]; then
    record_verify_mismatches_as_errors
  fi

  local ts state_json
  ts=$(date "+%Y-%m-%dT%H:%M:%S%z")
  state_json=$(jq -cn \
    --arg alias "$alias_name" --arg ts "$ts" --argjson verified "$verified" \
    --argjson enabled "$(printf '%s\n' "${ENABLED_NAMES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    --argjson disabled "$(printf '%s\n' "${DISABLED_NAMES[@]:-}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    --argjson errors "$ERRORS_JSON" --argjson mismatches "$VERIFY_MISMATCHES_JSON" \
    '{alias:$alias, ts:$ts, verified:$verified, enabled:$enabled, disabled:$disabled, errors:$errors, mismatches:$mismatches}')
  save_last_state "$state_json"

  local err_count
  err_count=$(printf '%s' "$ERRORS_JSON" | jq 'length')
  local result="ok"
  (( err_count > 0 )) && result="partial"
  log_event action alias alias "$alias_name" result "$result" errors "$err_count" verified "$verified"

  if (( err_count > 0 )); then
    echo
    echo "$err_count error(s) during toggle/verification." >&2
    return "$EXIT_PARTIAL"
  fi
  echo
  echo "Alias '$alias_name' applied and verified."
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
  local load_rc
  load_alias_map
  load_rc=$?
  if (( load_rc == 0 )); then
    local alias_count
    alias_count=$(printf '%s' "$ALIAS_MAP_JSON" | jq -r '
      [(.channel_aliases // {}) | to_entries[].value[]] | unique | length')
    echo "Aliases defined: $alias_count"
  elif (( load_rc == 1 )); then
    echo "Aliases defined: 0 (run --setup)"
  else
    echo "Aliases defined: unreadable (invalid keychain entry)"
  fi
  local last
  last=$(load_last_state) || last=""
  if [[ -n "$last" ]]; then
    echo
    echo "Last toggle:"
    printf '  ts:       %s\n' "$(printf '%s' "$last" | jq -r '.ts // ""')"
    printf '  alias:    %s\n' "$(printf '%s' "$last" | jq -r '.alias // .flag // .profile // ""')"
    printf '  enabled:  %s\n' "$(printf '%s' "$last" | jq -c '.enabled // []')"
    printf '  disabled: %s\n' "$(printf '%s' "$last" | jq -c '.disabled // []')"
    if printf '%s' "$last" | jq -e 'has("verified")' >/dev/null 2>&1; then
      printf '  verified: %s\n' "$(printf '%s' "$last" | jq -r '.verified')"
    fi
    local errs mismatches
    errs=$(printf '%s' "$last" | jq -c '.errors // []')
    [[ "$errs" != "[]" ]] && printf '  errors:   %s\n' "$errs"
    mismatches=$(printf '%s' "$last" | jq -c '.mismatches // []')
    [[ "$mismatches" != "[]" ]] && printf '  mismatches: %s\n' "$mismatches"
  else
    echo
    echo "No previous toggle recorded."
  fi
  echo
  echo "Current channel state:"
  cmd_list
}

# ---------------------------------------------------------------------------
# Interactive picker (alias-centric)
# ---------------------------------------------------------------------------
# Pure bash + ANSI escapes. No `tput cup`, no curses, no whiptail/dialog.
# Uses ANSI only — \e[2J + \e[H to clear, \e[<row>;<col>H to position,
# \e[?25l/\e[?25h to hide/show the cursor.
#
# Module-level state (re-initialized per alias edit):
#   PICK_NAMES[]        displayName per row (channel)
#   PICK_IDS[]          channel id per row
#   PICK_PLATFORMS[]    platform label per row
#   PICK_ACTIVE[]       current active state per row ("true"/"false")
#   PICK_SELECTED[]     "1"/"0" — is row in the alias being edited
#   PICK_CURSOR         current row index
#   PICK_TOP            top row of viewport
#   PICK_MSG            optional status message line
#   PICK_ALIAS          name of alias being edited
#   PICK_ALLOW_NEW      "1" when n/N should save and start another alias
#
# Picker control characters:
#   ↑/↓ or k/j      move cursor
#   g / G           jump to top / bottom
#   Space           toggle selection
#   Enter / s       save this alias and return (caller decides next step)
#   n               save this alias and start a new alias (return code 10)
#   d               delete this alias entirely (return code 11)
#   q / Esc         save and exit (return code 0)
#   Ctrl-C          cancel without saving anything from this picker run

PICK_NAMES=()
PICK_IDS=()
PICK_PLATFORMS=()
PICK_ACTIVE=()
PICK_SELECTED=()
PICK_CURSOR=0
PICK_TOP=0
PICK_MSG=""
PICK_ALIAS=""
PICK_ALLOW_NEW=1

# ANSI helpers — used in place of tput for portability.
ansi_clear()       { printf '\e[2J\e[H'; }
ansi_hide_cursor() { printf '\e[?25l'; }
ansi_show_cursor() { printf '\e[?25h'; }
ansi_cup()         { printf '\e[%d;%dH' "$1" "$2"; }   # row, col (1-indexed)
ansi_clear_line()  { printf '\e[2K'; }

term_rows() {
  local r=""
  if command -v stty >/dev/null 2>&1; then
    r=$(stty size 2>/dev/null | awk '{print $1}')
  fi
  [[ -z "$r" || "$r" -lt 5 ]] && r=24
  echo "$r"
}
term_cols() {
  local c=""
  if command -v stty >/dev/null 2>&1; then
    c=$(stty size 2>/dev/null | awk '{print $2}')
  fi
  [[ -z "$c" || "$c" -lt 20 ]] && c=80
  echo "$c"
}

picker_cleanup() {
  ansi_show_cursor
  stty sane 2>/dev/null || true
}

# Populate PICK_NAMES/IDS/PLATFORMS/ACTIVE from CHANNELS_JSON, sorted by
# (streamingPlatformId, displayName). Sets PICK_SELECTED based on whether
# each channel is currently in $ALIAS_MAP_JSON for $1 (the alias name).
picker_populate_for_alias() {
  local alias_name="$1"
  PICK_ALIAS="$alias_name"
  PICK_NAMES=()
  PICK_IDS=()
  PICK_PLATFORMS=()
  PICK_ACTIVE=()
  PICK_SELECTED=()
  PICK_CURSOR=0
  PICK_TOP=0
  PICK_MSG=""

  local sorted
  sorted=$(printf '%s' "$CHANNELS_JSON" | jq -c "
    ${PLATFORM_NAME_JQ}
    sort_by([platform_name, (.displayName // \"\" | ascii_downcase)])")

  # Build a fast lookup of selected ids: jq joins comma-separated.
  local selected_ids=""
  if [[ -n "$ALIAS_MAP_JSON" ]]; then
    selected_ids=$(printf '%s' "$ALIAS_MAP_JSON" | jq -r --arg a "$alias_name" '
      [(.channel_aliases // {}) | to_entries[]
        | select((.value // []) | index($a) != null)
        | .key] | join(",")')
  fi

  local id name plat active
  while IFS=$'\t' read -r id name plat active; do
    PICK_IDS+=("$id")
    PICK_NAMES+=("${name:-(unnamed)}")
    PICK_PLATFORMS+=("$plat")
    PICK_ACTIVE+=("$active")
    case ",$selected_ids," in
      *,"$id",*) PICK_SELECTED+=("1") ;;
      *)         PICK_SELECTED+=("0") ;;
    esac
  done < <(printf '%s' "$sorted" | jq -r "
    ${PLATFORM_NAME_JQ}
    .[] |
    [(.id|tostring),
     (.displayName // \"(unnamed)\"),
     platform_name,
     ((if .enabled != null then .enabled elif .active != null then .active else false end) | tostring)] | @tsv")
}

picker_count_selected() {
  local i n=0
  for (( i=0; i<${#PICK_SELECTED[@]}; i++ )); do
    [[ "${PICK_SELECTED[$i]}" == "1" ]] && n=$((n+1))
  done
  echo "$n"
}

picker_draw() {
  local rows cols
  rows=$(term_rows)
  cols=$(term_cols)
  ansi_clear

  ansi_cup 1 1
  printf '\e[1mRESTREAM ALIAS:\e[0m \e[1;36m%s\e[0m' "$PICK_ALIAS"
  local sel total
  sel=$(picker_count_selected)
  total=${#PICK_NAMES[@]}
  ansi_cup 1 $(( cols - 24 ))
  printf '\e[2m%d of %d selected\e[0m' "$sel" "$total"

  ansi_cup 3 1
  if [[ "$PICK_ALLOW_NEW" == "1" ]]; then
    printf '\e[2mUp/Dn or j/k  move   Space  toggle   Enter/s  save & exit   n  new alias\e[0m'
  else
    printf '\e[2mUp/Dn or j/k  move   Space  toggle   Enter/s  save & exit\e[0m'
  fi
  ansi_cup 4 1
  printf '\e[2md  delete this alias    q/Esc  save & exit    Ctrl-C  cancel\e[0m'

  local header_row=6
  ansi_cup "$header_row" 1
  printf '\e[1m  %-3s %-14s %-32s %-12s %s\e[0m' \
    "SEL" "PLATFORM" "CHANNEL" "ID" "ON"

  local n=${#PICK_NAMES[@]}
  local footer_rows=3
  local avail=$(( rows - header_row - 1 - footer_rows ))
  (( avail < 3 )) && avail=3

  if (( PICK_CURSOR < PICK_TOP )); then PICK_TOP=$PICK_CURSOR; fi
  if (( PICK_CURSOR >= PICK_TOP + avail )); then PICK_TOP=$(( PICK_CURSOR - avail + 1 )); fi
  (( PICK_TOP < 0 )) && PICK_TOP=0

  local i y=0
  for (( i=PICK_TOP; i<n && y<avail; i++, y++ )); do
    local row=$(( header_row + 1 + y ))
    ansi_cup "$row" 1
    local marker="  "
    local is_current=0
    if (( i == PICK_CURSOR )); then
      marker="> "
      is_current=1
      printf '\e[7m'
    fi
    local sel_mark="[ ]"
    if [[ "${PICK_SELECTED[$i]}" == "1" ]]; then
      if (( is_current )); then
        sel_mark=$'\e[1;32m[x]\e[0m\e[7m'
      else
        sel_mark=$'\e[1;32m[x]\e[0m'
      fi
    fi
    local live="off"
    if [[ "${PICK_ACTIVE[$i]}" == "true" ]]; then
      if (( is_current )); then
        live=$'\e[32mON\e[0m\e[7m'
      else
        live=$'\e[32mON\e[0m'
      fi
    fi
    local plat="${PICK_PLATFORMS[$i]}"
    (( ${#plat} > 14 )) && plat="${plat:0:14}"
    local name="${PICK_NAMES[$i]}"
    (( ${#name} > 32 )) && name="${name:0:29}..."
    local id="${PICK_IDS[$i]}"
    (( ${#id} > 12 )) && id="${id:0:12}"
    printf '%s%s %-14s %-32s %-12s %-3b' "$marker" "$sel_mark" "$plat" "$name" "$id" "$live"
    (( is_current )) && printf '\e[0m'
  done

  local ftop=$(( rows - footer_rows + 1 ))
  ansi_cup "$ftop" 1
  printf '\e[2m─────────────────────────────────────────────────────────────\e[0m'
  if [[ -n "$PICK_MSG" ]]; then
    ansi_cup $(( ftop + 1 )) 1
    printf '\e[33m%s\e[0m' "$PICK_MSG"
  fi
}

# Read a line of input visibly (for prompting alias name). Returns in REPLY.
picker_prompt_line() {
  local prompt="$1"
  local rows
  rows=$(term_rows)
  ansi_cup "$rows" 1
  ansi_clear_line
  ansi_show_cursor
  stty sane 2>/dev/null || true
  printf '%s' "$prompt"
  IFS= read -r REPLY
  ansi_hide_cursor
  stty -echo 2>/dev/null || true
}

# Sanitize/validate an alias name. Echoes the cleaned name, or empty on
# rejection. Prints reason to stderr if rejected.
sanitize_alias_name() {
  local name="$1"
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  if [[ -z "$name" ]]; then
    echo ""
    return 1
  fi
  if ! [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo ""
    return 1
  fi
  printf '%s' "$name"
}

# Update ALIAS_MAP_JSON: set the membership of $alias_name to PICK_SELECTED
# rows. Persists to keychain.
picker_save_to_alias_map() {
  local alias_name="$1"
  local previous_map="$ALIAS_MAP_JSON"
  local load_rc
  load_alias_map >/dev/null 2>&1
  load_rc=$?
  if (( load_rc == 1 )); then
    ALIAS_MAP_JSON="$previous_map"
  elif (( load_rc != 0 )); then
    ALIAS_MAP_JSON="$previous_map"
    return 1
  fi
  # Start from existing map (or empty).
  local map_json
  if [[ -n "$ALIAS_MAP_JSON" ]]; then
    map_json="$ALIAS_MAP_JSON"
  else
    map_json='{"channel_aliases":{}}'
  fi
  # Strip $alias_name from every channel's list first.
  map_json=$(printf '%s' "$map_json" | jq -c --arg a "$alias_name" '
    .channel_aliases = ((.channel_aliases // {}) | with_entries(
      .value = ((.value // []) | map(select(. != $a)))
    ))')
  # Then add it for every PICK_SELECTED=="1" row.
  local i
  for (( i=0; i<${#PICK_IDS[@]}; i++ )); do
    [[ "${PICK_SELECTED[$i]}" == "1" ]] || continue
    local id="${PICK_IDS[$i]}"
    map_json=$(printf '%s' "$map_json" | jq -c --arg id "$id" --arg a "$alias_name" '
      .channel_aliases[$id] = (((.channel_aliases[$id] // []) + [$a]) | unique)')
  done
  # Drop now-empty channel entries so the map stays clean.
  map_json=$(printf '%s' "$map_json" | jq -c '
    .channel_aliases = ((.channel_aliases // {}) | with_entries(
      select((.value // []) | length > 0)
    ))')
  save_alias_map "$map_json" || return 1
  ALIAS_MAP_JSON="$map_json"
}

# Delete an alias entirely (remove from every channel).
picker_delete_alias() {
  local alias_name="$1"
  local previous_map="$ALIAS_MAP_JSON"
  local load_rc
  load_alias_map >/dev/null 2>&1
  load_rc=$?
  if (( load_rc == 1 )); then
    ALIAS_MAP_JSON="$previous_map"
  elif (( load_rc != 0 )); then
    ALIAS_MAP_JSON="$previous_map"
    return 1
  fi
  local map_json
  if [[ -n "$ALIAS_MAP_JSON" ]]; then
    map_json="$ALIAS_MAP_JSON"
  else
    map_json='{"channel_aliases":{}}'
  fi
  map_json=$(printf '%s' "$map_json" | jq -c --arg a "$alias_name" '
    .channel_aliases = ((.channel_aliases // {}) | with_entries(
      .value = ((.value // []) | map(select(. != $a)))
    ) | with_entries(
      select((.value // []) | length > 0)
    ))')
  save_alias_map "$map_json" || return 1
  ALIAS_MAP_JSON="$map_json"
}

picker_finish_saved() {
  local alias_name="$1" rc="$2"
  if ! picker_save_to_alias_map "$alias_name"; then
    picker_cleanup
    trap - INT
    ansi_clear
    echo "Failed to save alias '$alias_name' to Keychain." >&2
    return "$EXIT_NETWORK"
  fi
  picker_cleanup
  trap - INT
  ansi_clear
  echo "Saved alias '$alias_name' ($(picker_count_selected) channel(s))."
  return "$rc"
}

# Run the picker for $1 = alias name. Returns:
#   0  saved & exit (q/Esc/Enter/s)
#   10 saved & user wants new alias (n)
#   11 alias deleted (d) — caller decides what next
#   130 user cancelled with Ctrl-C (no save)
run_picker() {
  local alias_name="$1"
  local allow_new="${2:-1}"

  # Trap Ctrl-C: cleanup + return 130. We can't `return` from a trap in a
  # straightforward way, so set a flag and check after read.
  PICK_CANCELLED=0
  PICK_ALLOW_NEW="$allow_new"
  # shellcheck disable=SC2064
  trap 'PICK_CANCELLED=1' INT

  picker_populate_for_alias "$alias_name"

  ansi_hide_cursor
  stty -echo 2>/dev/null || true

  local n=${#PICK_NAMES[@]}
  if (( n == 0 )); then
    picker_cleanup
    trap - INT
    echo "No channels found on your Restream account. Add some at restream.io first." >&2
    return "$EXIT_NO_MATCH"
  fi

  local esc_timeout=1
  if [[ ${BASH_VERSINFO[0]:-3} -ge 4 ]]; then
    esc_timeout="0.05"
  fi
  local key c2 c3
  while :; do
    if (( PICK_CANCELLED )); then
      picker_cleanup
      trap - INT
      ansi_clear
      echo "Cancelled. Changes for alias '$alias_name' NOT saved."
      return 130
    fi
    picker_draw
    if ! IFS= read -rsn1 key; then
      if (( PICK_CANCELLED )); then
        picker_cleanup
        trap - INT
        ansi_clear
        echo "Cancelled. Changes for alias '$alias_name' NOT saved."
        return 130
      fi
      break
    fi
    case "$key" in
      $'\e')
        c2=""
        IFS= read -rsn1 -t "$esc_timeout" c2 || c2=""
        if [[ -z "$c2" ]]; then
          # Bare Esc => save and exit.
          picker_finish_saved "$alias_name" 0
          return $?
        fi
        if [[ "$c2" == "[" || "$c2" == "O" ]]; then
          c3=""
          IFS= read -rsn1 -t "$esc_timeout" c3 || c3=""
          case "$c3" in
            A) (( PICK_CURSOR > 0 )) && PICK_CURSOR=$((PICK_CURSOR - 1)); PICK_MSG="" ;;
            B) (( PICK_CURSOR < n - 1 )) && PICK_CURSOR=$((PICK_CURSOR + 1)); PICK_MSG="" ;;
            *) : ;;
          esac
        fi
        ;;
      k) (( PICK_CURSOR > 0 )) && PICK_CURSOR=$((PICK_CURSOR - 1)); PICK_MSG="" ;;
      j) (( PICK_CURSOR < n - 1 )) && PICK_CURSOR=$((PICK_CURSOR + 1)); PICK_MSG="" ;;
      g) PICK_CURSOR=0; PICK_MSG="" ;;
      G) PICK_CURSOR=$(( n - 1 )); PICK_MSG="" ;;
      ' ')
        if [[ "${PICK_SELECTED[$PICK_CURSOR]}" == "1" ]]; then
          PICK_SELECTED[$PICK_CURSOR]="0"
        else
          PICK_SELECTED[$PICK_CURSOR]="1"
        fi
        PICK_MSG=""
        ;;
      ''|$'\n'|$'\r'|s|S)
        # Enter / s = save + exit picker.
        picker_finish_saved "$alias_name" 0
        return $?
        ;;
      n|N)
        if [[ "$PICK_ALLOW_NEW" == "1" ]]; then
          # Save current alias, signal caller to start another.
          picker_finish_saved "$alias_name" 10
          return $?
        fi
        PICK_MSG="Single-alias mode: press Enter/s/q/Esc to save and exit."
        ;;
      d|D)
        # Delete this alias (with confirm).
        picker_prompt_line "Delete alias '$alias_name' from every channel? [y/N]: "
        if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
          if ! picker_delete_alias "$alias_name"; then
            picker_cleanup
            trap - INT
            ansi_clear
            echo "Failed to delete alias '$alias_name' from Keychain." >&2
            return "$EXIT_NETWORK"
          fi
          picker_cleanup
          trap - INT
          ansi_clear
          echo "Deleted alias '$alias_name'."
          return 11
        else
          PICK_MSG="Delete cancelled."
        fi
        ;;
      q|Q)
        picker_finish_saved "$alias_name" 0
        return $?
        ;;
      *) : ;;
    esac
  done

  picker_cleanup
  trap - INT
  return 0
}

# Pick or create an alias name interactively. Echoes the name on stdout,
# returns 1 if user aborted.
prompt_alias_choice() {
  local existing
  existing=$(printf '%s' "$ALIAS_MAP_JSON" 2>/dev/null \
    | jq -r '[(.channel_aliases // {}) | to_entries[].value[]] | unique | .[]' 2>/dev/null \
    || true)
  echo >&2
  if [[ -n "$existing" ]]; then
    echo "Existing aliases:" >&2
    printf '  %s\n' $existing >&2
    echo >&2
    echo "Type an existing alias to edit it, or a new name to create one." >&2
  else
    echo "No aliases yet. Pick a name for your first one." >&2
    echo "Names: letters/digits/_/./- (e.g. 'reeethan', '3000ad', 'podcast')." >&2
  fi
  printf 'Alias name (empty to abort): ' >&2
  local name
  IFS= read -r name
  local clean
  clean=$(sanitize_alias_name "$name") || clean=""
  if [[ -z "$clean" ]]; then
    if [[ -z "$name" ]]; then
      echo "Aborted." >&2
    else
      echo "Rejected: only letters/digits/_/./- allowed (got '$name')." >&2
    fi
    return 1
  fi
  printf '%s' "$clean"
}

cmd_setup() {
  ensure_valid_tokens
  echo "Fetching channels..."
  fetch_channels
  local load_rc
  load_alias_map
  load_rc=$?
  if (( load_rc == 1 )); then
    ALIAS_MAP_JSON=""
  elif (( load_rc != 0 )); then
    return "$EXIT_NETWORK"
  fi

  while :; do
    local name
    if ! name=$(prompt_alias_choice); then
      break
    fi
    if [[ -z "$name" ]]; then
      break
    fi

    local rc
    run_picker "$name"
    rc=$?

    case "$rc" in
      0)
        # Saved. Ask whether to add another.
        printf 'Add another alias? [y/N]: '
        local ans
        IFS= read -r ans
        case "$ans" in
          y|Y|yes|YES) continue ;;
          *) break ;;
        esac
        ;;
      10)
        # 'n' inside picker — go straight to next alias.
        continue
        ;;
      11)
        # Deleted. Ask whether to do something else.
        printf 'Add or edit another alias? [y/N]: '
        local ans2
        IFS= read -r ans2
        case "$ans2" in
          y|Y|yes|YES) continue ;;
          *) break ;;
        esac
        ;;
      130)
        # Cancelled.
        break
        ;;
      "$EXIT_NETWORK")
        return "$EXIT_NETWORK"
        ;;
      *)
        return "$rc"
        ;;
    esac
  done

  local total_aliases=0 total_mapped=0
  if [[ -n "$ALIAS_MAP_JSON" ]]; then
    total_aliases=$(printf '%s' "$ALIAS_MAP_JSON" | jq '
      [(.channel_aliases // {}) | to_entries[].value[]] | unique | length')
    total_mapped=$(printf '%s' "$ALIAS_MAP_JSON" | jq '
      [(.channel_aliases // {}) | to_entries[] | select((.value // []) | length > 0)] | length')
  fi
  echo "Saved: $total_aliases alias(es) across $total_mapped channel(s)."
  echo "Run '--aliases' to list them, '--alias <name>' to apply."
  log_event action setup result ok aliases "$total_aliases"
  return "$EXIT_OK"
}

cmd_add_alias() {
  local name="$1"
  local clean
  clean=$(sanitize_alias_name "$name") || clean=""
  if [[ -z "$clean" ]]; then
    echo "error: alias name '$name' is invalid (use letters/digits/_/./-)." >&2
    return 2
  fi

  ensure_valid_tokens
  echo "Fetching channels..."
  fetch_channels
  local load_rc
  load_alias_map
  load_rc=$?
  if (( load_rc == 1 )); then
    ALIAS_MAP_JSON=""
  elif (( load_rc != 0 )); then
    return "$EXIT_NETWORK"
  fi

  local rc
  run_picker "$clean" 0
  rc=$?
  case "$rc" in
    0|10|11) ;;
    130) return "$EXIT_OK" ;;
    *) return "$rc" ;;
  esac

  local total_aliases=0
  if [[ -n "$ALIAS_MAP_JSON" ]]; then
    total_aliases=$(printf '%s' "$ALIAS_MAP_JSON" | jq '
      [(.channel_aliases // {}) | to_entries[].value[]] | unique | length')
  fi
  log_event action add-alias alias "$clean" result ok total "$total_aliases"
  return "$EXIT_OK"
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
  restream-channel-switch --add-alias NAME
  restream-channel-switch --list
  restream-channel-switch --aliases
  restream-channel-switch --alias NAME [--dry-run]
  restream-channel-switch --status
  restream-channel-switch --reset-creds
  restream-channel-switch --help

Options:
  --auth              Run OAuth flow; store client creds + tokens in Keychain.
  --setup             Interactive picker: create/edit aliases, multi-select
                      channels per alias, optionally add more aliases.
  --add-alias NAME    Open the picker scoped to a single alias (creates if missing).
  --list              List channels with current active state, sorted by platform.
  --aliases           List all defined aliases and channel counts.
  --alias NAME        Enable every channel tagged with alias NAME; disable the rest.
  --dry-run           With --alias: preview changes without applying.
  --status            Show user profile + last toggle + current state.
  --reset-creds       Delete stored client credentials, tokens, last state, and alias map.
  --help, -h          Show this help.

Quick-start (after --setup):
  Just pass the alias name. That's the whole API — one command per scene.

  restream-channel-switch --alias reeethan        # enable every channel tagged
                                                  # "reeethan", disable the rest
  restream-channel-switch --alias 3000ad          # swap to your other alias
  restream-channel-switch --alias reeethan --dry-run
                                                  # preview the toggle, no API
                                                  # writes — useful for testing

  restream-channel-switch --aliases               # list defined aliases + counts
  restream-channel-switch --list                  # current per-channel state

OBScene wiring:
  In OBScene Settings → each TriggerProfile → "Run on activate" field, paste:

    restream-channel-switch --alias reeethan

  (or whichever alias matches the profile). Replace "reeethan" with your real
  alias name; --dry-run is NOT recommended in production wiring.

Editing aliases later:
  --setup           re-run the full TUI; n to add new, d to delete current,
                    Tab to cycle aliases, Space to (un)select channels.
  --add-alias NAME  one-shot edit: opens picker for just NAME (creates if new).

Exit codes:
  0 success, 1 auth error, 2 network/API error,
  3 alias didn't match any channels, 4 partial success,
  5 no alias mapping yet (run --setup).

Deprecated (still work, with a warning):
  --flags             alias for --aliases
  --flag NAME         alias for --alias NAME
EOF
}

main() {
  local do_auth=0 do_setup=0 do_list=0 do_aliases=0 do_status=0 do_reset=0
  local alias_name="" dry=0
  local add_alias_name=""
  local saw_deprecated=0

  while (( $# > 0 )); do
    case "$1" in
      --auth)         do_auth=1 ;;
      --setup)        do_setup=1 ;;
      --list)         do_list=1 ;;
      --aliases)      do_aliases=1 ;;
      --status)       do_status=1 ;;
      --reset-creds)  do_reset=1 ;;
      --dry-run)      dry=1 ;;
      --alias)
        if (( $# < 2 )) || [[ "${2-}" == --* ]]; then
          echo "error: --alias requires a name." >&2
          return 2
        fi
        alias_name="${2-}"; shift ;;
      --alias=*)
        alias_name="${1#*=}"
        if [[ -z "$alias_name" ]]; then
          echo "error: --alias requires a name." >&2
          return 2
        fi
        ;;
      --add-alias)
        if (( $# < 2 )) || [[ "${2-}" == --* ]]; then
          echo "error: --add-alias requires a name." >&2
          return 2
        fi
        add_alias_name="${2-}"; shift ;;
      --add-alias=*)
        add_alias_name="${1#*=}"
        if [[ -z "$add_alias_name" ]]; then
          echo "error: --add-alias requires a name." >&2
          return 2
        fi
        ;;
      # Deprecated synonyms, kept for one release.
      --flags)
        echo "warning: --flags is deprecated; use --aliases. (still works for now)" >&2
        do_aliases=1; saw_deprecated=1 ;;
      --flag)
        echo "warning: --flag is deprecated; use --alias. (still works for now)" >&2
        if (( $# < 2 )) || [[ "${2-}" == --* ]]; then
          echo "error: --flag requires a name." >&2
          return 2
        fi
        alias_name="${2-}"; shift; saw_deprecated=1 ;;
      --flag=*)
        echo "warning: --flag is deprecated; use --alias. (still works for now)" >&2
        alias_name="${1#*=}"
        if [[ -z "$alias_name" ]]; then
          echo "error: --flag requires a name." >&2
          return 2
        fi
        saw_deprecated=1 ;;
      # Removed: --enable / --disable substring matchers.
      --enable|--enable=*|--disable|--disable=*)
        echo "error: --enable/--disable were removed in v2.1." >&2
        echo "       Substring matching of channel names was too imprecise." >&2
        echo "       Create an alias instead: --add-alias <name>" >&2
        return 2 ;;
      --profile|--profile=*)
        echo "error: --profile was removed. Use --alias <name> (see --setup)." >&2
        return 2 ;;
      -h|--help)      print_help; return 0 ;;
      *)              echo "unknown argument: $1" >&2; print_help >&2; return 2 ;;
    esac
    shift
  done

  if (( saw_deprecated )); then
    log_event action deprecated-flag-used result warn
  fi

  if (( do_reset )); then
    kc_delete "$KC_ACCOUNT_TOKENS"
    kc_delete "$KC_ACCOUNT_CLIENT"
    kc_delete "$KC_ACCOUNT_STATE"
    kc_delete "$KC_ACCOUNT_ALIASES"
    kc_delete "$KC_ACCOUNT_ALIASES_LEGACY"
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

  if [[ -n "$add_alias_name" ]]; then
    cmd_add_alias "$add_alias_name"
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
  if (( do_aliases )); then
    cmd_aliases
    return $?
  fi
  if [[ -n "$alias_name" ]]; then
    cmd_alias "$alias_name" "$dry"
    return $?
  fi

  print_help
  return "$EXIT_OK"
}

main "$@"
