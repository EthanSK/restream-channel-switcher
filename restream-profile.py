#!/usr/bin/env python3
"""restream-profile — toggle Restream streaming destinations on/off via the Restream API.

Ethan's OBS profile-change workflow:
    restream-profile --profile wreathen    # enable all channels whose displayName matches "wreathen*", disable others
    restream-profile --profile 3000ad      # enable 3000AD channels, disable others
    restream-profile --list                # show all channels + current active state
    restream-profile --enable "Wreathen YouTube" --disable "3000AD Twitch"
    restream-profile --status              # print last toggle + current state
    restream-profile --auth                # one-time OAuth flow

Tokens + client credentials live in macOS Keychain (service=com.restream-profile).
No plaintext secrets on disk. Refresh tokens rotate per Restream docs — we persist
each new refresh_token back to the keychain as it arrives.

API reference:
    Authorize:  https://api.restream.io/login
    Token:      https://api.restream.io/oauth/token
    List:       GET  https://api.restream.io/v2/user/channel/all
    Update:     PATCH https://api.restream.io/v2/user/channel/{id}   body: {"active": bool}
    Profile:    GET  https://api.restream.io/v2/user/profile
Scopes:      profile.read channels.read channels.write
"""
from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import http.server
import io
import json
import logging
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from dataclasses import dataclass
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
KEYCHAIN_SERVICE = "com.restream-profile"
KEYCHAIN_ACCOUNT_TOKENS = "tokens"
KEYCHAIN_ACCOUNT_CLIENT = "client"
KEYCHAIN_ACCOUNT_STATE = "last-state"

AUTHORIZE_URL = "https://api.restream.io/login"
TOKEN_URL = "https://api.restream.io/oauth/token"
API_BASE = "https://api.restream.io/v2"

REDIRECT_PORT = 8976
REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}/callback"

SCOPES = "profile.read channels.read channels.write"

LOG_DIR = Path.home() / "Library" / "Logs" / "restream-profile"
LOG_FILE = LOG_DIR / "toggle.log"
LOG_MAX_BYTES = 10 * 1024 * 1024  # 10 MB

USER_AGENT = "restream-profile/1.0 (+https://github.com/EthanSK/restream-profile-switcher)"

EXIT_OK = 0
EXIT_AUTH = 1
EXIT_NETWORK = 2
EXIT_NO_MATCH = 3
EXIT_PARTIAL = 4

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_DIR.mkdir(parents=True, exist_ok=True)
_json_logger = logging.getLogger("restream-profile.json")
_json_logger.setLevel(logging.INFO)
_json_logger.propagate = False
if not _json_logger.handlers:
    _handler = RotatingFileHandler(LOG_FILE, maxBytes=LOG_MAX_BYTES, backupCount=3)
    _handler.setFormatter(logging.Formatter("%(message)s"))
    _json_logger.addHandler(_handler)


def log_event(**fields) -> None:
    fields.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
    try:
        _json_logger.info(json.dumps(fields, sort_keys=True, default=str))
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Keychain helpers
# ---------------------------------------------------------------------------
def kc_get(account: str) -> Optional[str]:
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.rstrip("\n")
    except subprocess.CalledProcessError:
        return None


def kc_set(account: str, value: str) -> None:
    # -U updates if exists
    subprocess.run(
        ["security", "add-generic-password", "-U",
         "-s", KEYCHAIN_SERVICE, "-a", account, "-w", value],
        check=True, capture_output=True, text=True,
    )


def kc_delete(account: str) -> None:
    subprocess.run(
        ["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account],
        capture_output=True, text=True,
    )


# ---------------------------------------------------------------------------
# Credential & token persistence
# ---------------------------------------------------------------------------
@dataclass
class ClientCreds:
    client_id: str
    client_secret: str

    def to_json(self) -> str:
        return json.dumps({"client_id": self.client_id, "client_secret": self.client_secret})

    @classmethod
    def from_json(cls, s: str) -> "ClientCreds":
        d = json.loads(s)
        return cls(client_id=d["client_id"], client_secret=d["client_secret"])


@dataclass
class Tokens:
    access_token: str
    refresh_token: str
    access_expires_at: float  # unix seconds

    def to_json(self) -> str:
        return json.dumps({
            "access_token": self.access_token,
            "refresh_token": self.refresh_token,
            "access_expires_at": self.access_expires_at,
        })

    @classmethod
    def from_json(cls, s: str) -> "Tokens":
        d = json.loads(s)
        return cls(
            access_token=d["access_token"],
            refresh_token=d["refresh_token"],
            access_expires_at=float(d["access_expires_at"]),
        )


def load_client_creds() -> Optional[ClientCreds]:
    raw = kc_get(KEYCHAIN_ACCOUNT_CLIENT)
    if not raw:
        return None
    try:
        return ClientCreds.from_json(raw)
    except Exception:
        return None


def save_client_creds(c: ClientCreds) -> None:
    kc_set(KEYCHAIN_ACCOUNT_CLIENT, c.to_json())


def load_tokens() -> Optional[Tokens]:
    raw = kc_get(KEYCHAIN_ACCOUNT_TOKENS)
    if not raw:
        return None
    try:
        return Tokens.from_json(raw)
    except Exception:
        return None


def save_tokens(t: Tokens) -> None:
    kc_set(KEYCHAIN_ACCOUNT_TOKENS, t.to_json())


def load_last_state() -> Optional[dict]:
    raw = kc_get(KEYCHAIN_ACCOUNT_STATE)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def save_last_state(state: dict) -> None:
    kc_set(KEYCHAIN_ACCOUNT_STATE, json.dumps(state))


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
class APIError(Exception):
    def __init__(self, status: int, body: str, url: str):
        super().__init__(f"{status} {url}: {body[:300]}")
        self.status = status
        self.body = body
        self.url = url


def http_request(method: str, url: str, *, headers: Optional[dict] = None,
                 data: Optional[bytes] = None, timeout: float = 15.0) -> tuple[int, bytes, dict]:
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("User-Agent", USER_AGENT)
    req.add_header("Accept-Encoding", "gzip")
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            return resp.status, raw, dict(resp.headers)
    except urllib.error.HTTPError as e:
        raw = e.read() or b""
        if e.headers.get("Content-Encoding") == "gzip":
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        return e.code, raw, dict(e.headers or {})


# ---------------------------------------------------------------------------
# OAuth flow
# ---------------------------------------------------------------------------
class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    server_version = "restream-profile/1.0"
    result: dict = {}

    def do_GET(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404); self.end_headers(); self.wfile.write(b"not found"); return
        qs = urllib.parse.parse_qs(parsed.query)
        _CallbackHandler.result = {k: v[0] for k, v in qs.items()}
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        msg = "Authorization captured. You can close this tab."
        if "error" in _CallbackHandler.result:
            msg = f"Error: {_CallbackHandler.result.get('error')}"
        self.wfile.write(f"<html><body><h3>{msg}</h3></body></html>".encode())
        # signal shutdown
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, *_a, **_kw):  # silence stderr noise
        pass


def _start_callback_server() -> http.server.HTTPServer:
    httpd = http.server.HTTPServer(("127.0.0.1", REDIRECT_PORT), _CallbackHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def prompt_client_creds() -> ClientCreds:
    print("Restream OAuth app credentials are required (one-time).")
    print("Create an app at https://developers.restream.io/apps")
    print(f"  - Set Redirect URI to: {REDIRECT_URI}")
    print(f"  - Scopes needed: {SCOPES}")
    print()
    client_id = input("Client ID: ").strip()
    client_secret = input("Client Secret: ").strip()
    if not client_id or not client_secret:
        sys.exit("Client ID and Client Secret are required.")
    creds = ClientCreds(client_id=client_id, client_secret=client_secret)
    save_client_creds(creds)
    print("Stored in macOS Keychain (service=com.restream-profile, account=client).")
    return creds


def do_auth_flow() -> Tokens:
    creds = load_client_creds() or prompt_client_creds()
    state = secrets.token_urlsafe(24)
    params = {
        "response_type": "code",
        "client_id": creds.client_id,
        "redirect_uri": REDIRECT_URI,
        "state": state,
        "scope": SCOPES,
    }
    authorize_url = f"{AUTHORIZE_URL}?{urllib.parse.urlencode(params)}"
    print("Opening browser for Restream authorization…")
    print(f"If it doesn't open, visit:\n  {authorize_url}\n")

    httpd = _start_callback_server()
    try:
        webbrowser.open(authorize_url)
        # Wait for callback (server shuts down when request arrives)
        deadline = time.time() + 300
        while httpd.socket.fileno() != -1 and time.time() < deadline:
            time.sleep(0.2)
        if not _CallbackHandler.result:
            sys.exit("Timed out waiting for OAuth callback.")
    finally:
        try:
            httpd.server_close()
        except Exception:
            pass

    r = _CallbackHandler.result
    if "error" in r:
        sys.exit(f"OAuth error: {r['error']} - {r.get('error_description','')}")
    if r.get("state") != state:
        sys.exit("OAuth state mismatch — aborting (possible CSRF).")
    code = r.get("code")
    if not code:
        sys.exit("No authorization code returned.")

    tokens = exchange_code_for_tokens(creds, code)
    save_tokens(tokens)
    print("Tokens saved to Keychain.")
    log_event(action="auth", result="ok")
    return tokens


def _token_request(creds: ClientCreds, body: dict) -> dict:
    basic = base64.b64encode(f"{creds.client_id}:{creds.client_secret}".encode()).decode()
    status, raw, _ = http_request(
        "POST", TOKEN_URL,
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        data=urllib.parse.urlencode(body).encode(),
        timeout=20.0,
    )
    if status != 200:
        raise APIError(status, raw.decode("utf-8", "replace"), TOKEN_URL)
    return json.loads(raw)


def exchange_code_for_tokens(creds: ClientCreds, code: str) -> Tokens:
    data = _token_request(creds, {
        "grant_type": "authorization_code",
        "redirect_uri": REDIRECT_URI,
        "code": code,
    })
    return _tokens_from_response(data)


def refresh_tokens(creds: ClientCreds, refresh_token: str) -> Tokens:
    data = _token_request(creds, {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    })
    return _tokens_from_response(data)


def _tokens_from_response(data: dict) -> Tokens:
    access = data.get("access_token") or data.get("accessToken")
    refresh = data.get("refresh_token") or data.get("refreshToken")
    expires_in = data.get("expires_in") or data.get("accessTokenExpiresIn") or 3600
    if not access or not refresh:
        raise RuntimeError(f"Token response missing fields: {list(data.keys())}")
    # 60s safety buffer
    return Tokens(
        access_token=access,
        refresh_token=refresh,
        access_expires_at=time.time() + int(expires_in) - 60,
    )


def ensure_valid_tokens() -> tuple[ClientCreds, Tokens]:
    creds = load_client_creds()
    if not creds:
        print("No client credentials found. Run --auth first.", file=sys.stderr)
        sys.exit(EXIT_AUTH)
    tokens = load_tokens()
    if not tokens:
        print("No tokens found. Run --auth first.", file=sys.stderr)
        sys.exit(EXIT_AUTH)
    if tokens.access_expires_at <= time.time():
        try:
            tokens = refresh_tokens(creds, tokens.refresh_token)
            save_tokens(tokens)
            log_event(action="refresh", result="ok")
        except APIError as e:
            log_event(action="refresh", result="fail", status=e.status, body=e.body[:200])
            print("Refresh failed. Re-run --auth.", file=sys.stderr)
            sys.exit(EXIT_AUTH)
    return creds, tokens


# ---------------------------------------------------------------------------
# API calls
# ---------------------------------------------------------------------------
def _api(method: str, path: str, *, tokens: Tokens, creds: ClientCreds,
         body: Optional[dict] = None, _retried: bool = False) -> tuple[int, bytes]:
    url = API_BASE + path
    headers = {"Authorization": f"Bearer {tokens.access_token}"}
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    status, raw, _ = http_request(method, url, headers=headers, data=data)
    if status == 401 and not _retried:
        # Maybe token just expired server-side. Try one refresh.
        try:
            new_tokens = refresh_tokens(creds, tokens.refresh_token)
            save_tokens(new_tokens)
            tokens.access_token = new_tokens.access_token
            tokens.refresh_token = new_tokens.refresh_token
            tokens.access_expires_at = new_tokens.access_expires_at
            return _api(method, path, tokens=tokens, creds=creds, body=body, _retried=True)
        except APIError as e:
            log_event(action="refresh-on-401", result="fail", status=e.status)
            print("Authorization error and refresh failed. Re-run --auth.", file=sys.stderr)
            sys.exit(EXIT_AUTH)
    return status, raw


def list_channels(tokens: Tokens, creds: ClientCreds) -> list[dict]:
    status, raw = _api("GET", "/user/channel/all", tokens=tokens, creds=creds)
    if status != 200:
        raise APIError(status, raw.decode("utf-8", "replace"), "/user/channel/all")
    return json.loads(raw)


def set_channel_active(tokens: Tokens, creds: ClientCreds, channel_id: int, active: bool) -> None:
    status, raw = _api("PATCH", f"/user/channel/{channel_id}",
                       tokens=tokens, creds=creds, body={"active": active})
    if status not in (200, 204):
        raise APIError(status, raw.decode("utf-8", "replace"), f"/user/channel/{channel_id}")


def get_profile(tokens: Tokens, creds: ClientCreds) -> dict:
    status, raw = _api("GET", "/user/profile", tokens=tokens, creds=creds)
    if status != 200:
        raise APIError(status, raw.decode("utf-8", "replace"), "/user/profile")
    return json.loads(raw)


# ---------------------------------------------------------------------------
# Profile logic
# ---------------------------------------------------------------------------
def match_channels(channels: list[dict], profile: str) -> list[dict]:
    """Case-insensitive substring match against displayName."""
    needle = profile.strip().lower()
    matches = [c for c in channels if needle in (c.get("displayName") or "").lower()]
    return matches


def find_channel_by_name(channels: list[dict], name: str) -> Optional[dict]:
    needle = name.strip().lower()
    exact = [c for c in channels if (c.get("displayName") or "").lower() == needle]
    if exact:
        return exact[0]
    subs = [c for c in channels if needle in (c.get("displayName") or "").lower()]
    if len(subs) == 1:
        return subs[0]
    if len(subs) > 1:
        raise RuntimeError(f"Ambiguous channel name '{name}' — matches {[c['displayName'] for c in subs]}")
    return None


def apply_toggles(tokens: Tokens, creds: ClientCreds,
                  to_enable: list[dict], to_disable: list[dict]) -> tuple[list, list, list]:
    """Returns (enabled_ok, disabled_ok, errors)."""
    enabled_ok, disabled_ok, errors = [], [], []
    for ch in to_enable:
        try:
            set_channel_active(tokens, creds, ch["id"], True)
            enabled_ok.append(ch)
            print(f"  ✓ enabled  {ch['displayName']} (id {ch['id']})")
        except APIError as e:
            errors.append({"channel": ch["displayName"], "op": "enable", "error": str(e)})
            print(f"  ✗ enable failed: {ch['displayName']}: {e}", file=sys.stderr)
    for ch in to_disable:
        try:
            set_channel_active(tokens, creds, ch["id"], False)
            disabled_ok.append(ch)
            print(f"  ✓ disabled {ch['displayName']} (id {ch['id']})")
        except APIError as e:
            errors.append({"channel": ch["displayName"], "op": "disable", "error": str(e)})
            print(f"  ✗ disable failed: {ch['displayName']}: {e}", file=sys.stderr)
    return enabled_ok, disabled_ok, errors


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_list(tokens: Tokens, creds: ClientCreds) -> int:
    channels = list_channels(tokens, creds)
    channels.sort(key=lambda c: (c.get("displayName") or "").lower())
    width = max((len(c.get("displayName") or "") for c in channels), default=20)
    print(f"{'STATE':<8} {'ID':<10} {'PLATFORM':<10} NAME")
    for c in channels:
        state = "ON " if c.get("active") else "off"
        pid = c.get("streamingPlatformId") or c.get("platformId") or ""
        print(f"{state:<8} {c.get('id'):<10} {pid:<10} {c.get('displayName')}")
    print(f"\n{len(channels)} channel(s), {sum(1 for c in channels if c.get('active'))} active.")
    return EXIT_OK


def cmd_profile(tokens: Tokens, creds: ClientCreds, profile: str, dry_run: bool) -> int:
    channels = list_channels(tokens, creds)
    matches = match_channels(channels, profile)
    if not matches:
        print(f"No channels match profile '{profile}'.", file=sys.stderr)
        log_event(action="profile", profile=profile, result="no-match")
        return EXIT_NO_MATCH
    keep_ids = {c["id"] for c in matches}
    to_enable = [c for c in matches if not c.get("active")]
    to_disable = [c for c in channels if c["id"] not in keep_ids and c.get("active")]
    # also re-assert enabled state for matches that are already active? no need unless explicit
    print(f"Profile '{profile}':")
    print(f"  matches ({len(matches)}): {[c['displayName'] for c in matches]}")
    print(f"  will enable  ({len(to_enable)}): {[c['displayName'] for c in to_enable]}")
    print(f"  will disable ({len(to_disable)}): {[c['displayName'] for c in to_disable]}")
    if dry_run:
        print("(dry-run; no changes)")
        return EXIT_OK
    enabled_ok, disabled_ok, errors = apply_toggles(tokens, creds, to_enable, to_disable)
    state = {
        "profile": profile,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "enabled": [c["displayName"] for c in enabled_ok],
        "disabled": [c["displayName"] for c in disabled_ok],
        "errors": errors,
    }
    save_last_state(state)
    log_event(action="profile", profile=profile,
              enabled=state["enabled"], disabled=state["disabled"],
              errors=errors, result="partial" if errors else "ok")
    if errors:
        print(f"\n{len(errors)} error(s) during toggle.", file=sys.stderr)
        return EXIT_PARTIAL
    print(f"\nProfile '{profile}' applied.")
    return EXIT_OK


def cmd_enable_disable(tokens: Tokens, creds: ClientCreds,
                        enable_names: list[str], disable_names: list[str]) -> int:
    channels = list_channels(tokens, creds)
    to_enable, to_disable, errors = [], [], []
    for name in enable_names:
        try:
            c = find_channel_by_name(channels, name)
        except RuntimeError as e:
            print(str(e), file=sys.stderr); return EXIT_NO_MATCH
        if not c:
            print(f"No channel matches '{name}'", file=sys.stderr); return EXIT_NO_MATCH
        to_enable.append(c)
    for name in disable_names:
        try:
            c = find_channel_by_name(channels, name)
        except RuntimeError as e:
            print(str(e), file=sys.stderr); return EXIT_NO_MATCH
        if not c:
            print(f"No channel matches '{name}'", file=sys.stderr); return EXIT_NO_MATCH
        to_disable.append(c)
    enabled_ok, disabled_ok, errors = apply_toggles(tokens, creds, to_enable, to_disable)
    log_event(action="enable-disable",
              enabled=[c["displayName"] for c in enabled_ok],
              disabled=[c["displayName"] for c in disabled_ok],
              errors=errors, result="partial" if errors else "ok")
    return EXIT_PARTIAL if errors else EXIT_OK


def cmd_status(tokens: Tokens, creds: ClientCreds) -> int:
    try:
        profile = get_profile(tokens, creds)
        print(f"User: {profile.get('username')} (id={profile.get('id')}, email={profile.get('email')})")
    except APIError as e:
        print(f"Profile check failed: {e}", file=sys.stderr)
    last = load_last_state()
    if last:
        print("\nLast toggle:")
        print(f"  ts:       {last.get('ts')}")
        print(f"  profile:  {last.get('profile')}")
        print(f"  enabled:  {last.get('enabled')}")
        print(f"  disabled: {last.get('disabled')}")
        if last.get("errors"):
            print(f"  errors:   {last['errors']}")
    else:
        print("\nNo previous toggle recorded.")
    print("\nCurrent channel state:")
    return cmd_list(tokens, creds)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="restream-profile",
        description="Toggle Restream streaming destinations via the Restream API.",
    )
    p.add_argument("--auth", action="store_true", help="Run OAuth flow to obtain/refresh tokens.")
    p.add_argument("--list", action="store_true", help="List channels with current active state.")
    p.add_argument("--profile", help="Enable channels matching NAME (case-insensitive substring on displayName); disable all others.")
    p.add_argument("--enable", action="append", default=[], help="Enable a channel by name (can be repeated).")
    p.add_argument("--disable", action="append", default=[], help="Disable a channel by name (can be repeated).")
    p.add_argument("--status", action="store_true", help="Print user profile + last toggle + current state.")
    p.add_argument("--dry-run", action="store_true", help="Show what --profile would do without applying.")
    p.add_argument("--reset-creds", action="store_true", help="Delete stored client credentials + tokens.")
    return p


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if args.reset_creds:
        kc_delete(KEYCHAIN_ACCOUNT_TOKENS)
        kc_delete(KEYCHAIN_ACCOUNT_CLIENT)
        kc_delete(KEYCHAIN_ACCOUNT_STATE)
        print("Cleared keychain entries for com.restream-profile.")
        return EXIT_OK

    if args.auth:
        do_auth_flow()
        return EXIT_OK

    # Default: refresh/validate tokens first
    try:
        creds, tokens = ensure_valid_tokens()
    except APIError as e:
        log_event(action="startup", result="api-error", status=e.status)
        print(f"API error: {e}", file=sys.stderr)
        return EXIT_NETWORK

    try:
        if args.status:
            return cmd_status(tokens, creds)
        if args.list:
            return cmd_list(tokens, creds)
        if args.profile:
            return cmd_profile(tokens, creds, args.profile, args.dry_run)
        if args.enable or args.disable:
            return cmd_enable_disable(tokens, creds, args.enable, args.disable)
        build_parser().print_help()
        return EXIT_OK
    except APIError as e:
        log_event(action="api-error", status=e.status, url=e.url, body=e.body[:200])
        print(f"API error: {e}", file=sys.stderr)
        return EXIT_NETWORK
    except urllib.error.URLError as e:
        log_event(action="network-error", error=str(e))
        print(f"Network error: {e}", file=sys.stderr)
        return EXIT_NETWORK


if __name__ == "__main__":
    sys.exit(main())
