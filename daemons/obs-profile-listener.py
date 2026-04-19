#!/usr/bin/env python3
"""obs-profile-listener — listens for OBS CurrentProfileChanged events via
obs-websocket and shells out to restream-profile.py with the new profile name.

Requires: obsws-python  (pip3 install --user obsws-python)

Config:
  - obs-websocket password is read from
    ~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json
  - port defaults to 4455
  - restream-profile CLI path defaults to the sibling directory; override with
    RESTREAM_PROFILE_CLI env var.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

try:
    import obsws_python as obs  # type: ignore
except ImportError:
    sys.stderr.write(
        "FATAL: obsws-python not installed. Run: pip3 install --user obsws-python\n"
    )
    sys.exit(1)


HOME = Path.home()
OBS_WS_CONFIG = (
    HOME
    / "Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json"
)
DEFAULT_CLI = str(
    HOME / "Projects/restream-profile-switcher/restream-profile.py"
)
RESTREAM_PROFILE_CLI = os.environ.get("RESTREAM_PROFILE_CLI", DEFAULT_CLI)


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
    sys.stderr.write(f"[{ts}] {msg}\n")
    sys.stderr.flush()


def load_ws_config() -> tuple[str, int, str]:
    if not OBS_WS_CONFIG.exists():
        log(f"FATAL: obs-websocket config not found at {OBS_WS_CONFIG}")
        sys.exit(1)
    with OBS_WS_CONFIG.open() as f:
        cfg = json.load(f)
    host = "127.0.0.1"
    port = int(cfg.get("server_port", 4455))
    password = cfg.get("server_password", "")
    if cfg.get("auth_required", True) and not password:
        log("FATAL: obs-websocket auth_required but no password in config")
        sys.exit(1)
    return host, port, password


def fire_cli(profile_name: str) -> None:
    log(f"CurrentProfileChanged -> {profile_name}; exec CLI")
    try:
        result = subprocess.run(
            ["python3", RESTREAM_PROFILE_CLI, "--profile", profile_name],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.stdout.strip():
            log(f"CLI stdout: {result.stdout.strip()}")
        if result.stderr.strip():
            log(f"CLI stderr: {result.stderr.strip()}")
        log(f"CLI exit: {result.returncode}")
    except subprocess.TimeoutExpired:
        log("ERROR: CLI timed out after 30s")
    except FileNotFoundError:
        log(f"ERROR: CLI not found at {RESTREAM_PROFILE_CLI}")
    except Exception as e:
        log(f"ERROR: CLI exec failed: {e}")


class Listener:
    def __init__(self, host: str, port: int, password: str):
        self.host = host
        self.port = port
        self.password = password
        self.events: obs.EventClient | None = None
        self._should_stop = False

    def _on_current_profile_changed(self, event) -> None:
        # obs-websocket v5 payload: { "profileName": "..." }
        name = getattr(event, "profile_name", None)
        if name is None:
            # some versions expose attribute differently
            raw = getattr(event, "__dict__", {}) or {}
            name = raw.get("profileName") or raw.get("profile_name")
        if not name:
            log(f"WARN: CurrentProfileChanged event without profileName: {vars(event)}")
            return
        fire_cli(name)

    def run(self) -> None:
        while not self._should_stop:
            try:
                log(f"Connecting to ws://{self.host}:{self.port}")
                self.events = obs.EventClient(
                    host=self.host,
                    port=self.port,
                    password=self.password,
                    subs=(
                        obs.Subs.LOW_VOLUME
                        if hasattr(obs, "Subs")
                        else 0x3FF
                    ),
                )
                self.events.callback.register(self._on_current_profile_changed)
                # register may take snake-cased handler name — ensure binding
                log("Connected. Listening for CurrentProfileChanged...")
                while not self._should_stop:
                    time.sleep(1)
            except Exception as e:
                log(f"Connection error: {e}; reconnecting in 5s")
                time.sleep(5)
            finally:
                try:
                    if self.events is not None:
                        self.events.disconnect()
                except Exception:
                    pass
                self.events = None

    def stop(self) -> None:
        self._should_stop = True


def main() -> int:
    host, port, password = load_ws_config()
    log(f"restream-profile CLI: {RESTREAM_PROFILE_CLI}")
    listener = Listener(host, port, password)

    def _sigterm(signum, frame):
        log(f"Signal {signum} received; stopping")
        listener.stop()

    signal.signal(signal.SIGTERM, _sigterm)
    signal.signal(signal.SIGINT, _sigterm)

    listener.run()
    log("Exited cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
