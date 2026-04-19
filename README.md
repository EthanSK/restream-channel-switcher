# restream-profile-switcher

A pure-bash CLI that toggles your Restream.io streaming destinations on/off in one shot. Point it at a "profile" name and it enables every Restream channel whose `displayName` contains that string and disables all the others. Designed to be fired from a profile-change hook (e.g. [OBScene](https://github.com/EthanSK/OBScene)) so switching scene profiles automatically flips which destinations go live.

Why bash: no Python, no runtime, no virtualenv — just standard Unix tools. Portable across macOS and Linux (macOS uses `security` for the Keychain; adapt the three `kc_*` functions for other platforms if needed).

## Dependencies

- `bash` (4+ recommended; the script uses `readarray`-free patterns so bash 3.2 should also work)
- `curl`
- `jq` — for JSON parsing (install via `brew install jq` or your distro's package manager)
- `security` — macOS Keychain CLI (ships with macOS)
- `nc` — for the one-shot OAuth callback listener (ships with macOS)
- `openssl` — for the OAuth `state` nonce (ships with macOS)
- `open` — to launch the browser during `--auth` (ships with macOS; on Linux substitute `xdg-open`)

## Install

```bash
git clone git@github.com:EthanSK/restream-profile-switcher.git ~/Projects/restream-profile-switcher
ln -s ~/Projects/restream-profile-switcher/restream-profile.sh ~/.local/bin/restream-profile
chmod +x ~/Projects/restream-profile-switcher/restream-profile.sh
```

Make sure `~/.local/bin` is on your `$PATH`.

## One-time OAuth setup

1. Go to <https://developers.restream.io/apps> and create a new application.
2. Set the redirect URI to exactly: `http://localhost:8976/callback`
3. Enable the scopes: `profile.read`, `channels.read`, `channels.write`
4. Copy the `Client ID` and `Client Secret`.

Then run:

```bash
restream-profile --auth
```

The script prompts for Client ID + Client Secret (stored in Keychain), opens the Restream authorize page in your browser, catches the `?code=...` callback with a one-shot `nc` listener on port 8976, exchanges it for tokens, and saves them to Keychain.

## Usage

```bash
restream-profile --list                                    # all channels + on/off state
restream-profile --profile wreathen                        # enable channels matching "wreathen", disable others
restream-profile --profile 3000ad                          # enable "3000AD*", disable others
restream-profile --profile wreathen --dry-run              # preview only, no API writes
restream-profile --enable "YouTube" --disable "Twitch"     # fine-grained; repeatable
restream-profile --status                                  # user info + last toggle + current state
restream-profile --reset-creds                             # wipe all keychain entries
restream-profile --help
```

Profile matching is case-insensitive substring against each channel's `displayName`.

## OBScene integration (intended use case)

Ethan's [OBScene](https://github.com/EthanSK/OBScene) app exposes a per-profile "Run Script" field. Point it at this script and OBScene will fire it on profile activation:

```
/Users/you/.local/bin/restream-profile --profile wreathen
```

No daemons, no USB watchers, no launchd plists — OBScene handles the trigger; this script handles the API call. That's the whole loop.

## Exit codes

| Code | Meaning |
| ---- | ------- |
| 0    | Success |
| 1    | Auth error (tokens bad / expired / revoked — re-run `--auth`) |
| 2    | Network / API error |
| 3    | Profile name didn't match any channels |
| 4    | Partial success — some channels toggled, some failed |

## Keychain entries

| Service | Account | Content |
| --- | --- | --- |
| `com.restream-profile` | `client`     | `{client_id, client_secret}` |
| `com.restream-profile` | `tokens`     | `{access_token, refresh_token, access_expires_at}` |
| `com.restream-profile` | `last-state` | Last `--profile` run summary |

Inspect with:

```bash
security find-generic-password -s com.restream-profile -a tokens -w
```

## Logging

Single-line JSON events per run at `~/Library/Logs/restream-profile/toggle.log`. Rotates manually — when the file exceeds 10 MB it's renamed to `toggle.log.1`.

## Restream API endpoints used

| Purpose | Method | URL |
| --- | --- | --- |
| Authorize | GET | `https://api.restream.io/login?response_type=code&client_id=...&redirect_uri=...&state=...` |
| Token exchange / refresh | POST | `https://api.restream.io/oauth/token` (HTTP Basic `client_id:client_secret`) |
| List channels | GET | `https://api.restream.io/v2/user/channel/all` |
| Update channel | PATCH | `https://api.restream.io/v2/user/channel/{id}` body `{"active": true\|false}` |
| Profile | GET | `https://api.restream.io/v2/user/profile` |

Refresh tokens rotate on every refresh — the script persists the new one back to Keychain automatically.

## License

MIT — see [LICENSE](LICENSE).
