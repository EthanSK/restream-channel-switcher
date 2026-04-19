# restream-profile-switcher

Toggle Restream streaming destinations on/off from the command line, for use with OBS profile-change hooks (USB plug-in → switch OBS profile → run this script → flip the right Restream channels).

## Install

```bash
git clone git@github.com:EthanSK/restream-profile-switcher.git ~/Projects/restream-profile-switcher
ln -s ~/Projects/restream-profile-switcher/restream-profile.py ~/.local/bin/restream-profile
chmod +x ~/Projects/restream-profile-switcher/restream-profile.py
```

Uses only the Python stdlib. Tested on Python 3.11+. Secrets stored in macOS Keychain (service `com.restream-profile`).

## One-time OAuth app setup

1. Go to <https://developers.restream.io/apps> and create a new application.
2. Set the redirect URI to exactly: `http://localhost:8976/callback`
3. Enable the scopes: `profile.read`, `channels.read`, `channels.write`
4. Note the `Client ID` and `Client Secret`.

Then run:

```bash
restream-profile --auth
```

The script will prompt for Client ID + Client Secret (stored in Keychain), open the authorize page, and capture the callback.

## Usage

```bash
restream-profile --list                    # show all channels + current on/off state
restream-profile --profile wreathen        # enable all channels whose displayName contains "wreathen", disable the rest
restream-profile --profile 3000ad          # enable all "3000AD*" channels, disable the rest
restream-profile --profile wreathen --dry-run   # preview only, no API writes
restream-profile --enable "Wreathen YouTube" --disable "3000AD Twitch"
restream-profile --status                  # user info + last toggle + current state
restream-profile --reset-creds             # nuke all keychain entries
```

Profile matching is case-insensitive substring against each channel's `displayName`.

## OBS integration

OBS has a `tools/obs-advanced-cli` or a profile-change script hook (depending on version). The simplest integration:

```bash
# in your OBS profile-switch script
/Users/you/.local/bin/restream-profile --profile wreathen
```

## Exit codes

| Code | Meaning |
| ---- | ------- |
| 0    | Success |
| 1    | Auth error (tokens bad / expired / revoked — re-run `--auth`) |
| 2    | Network / API error |
| 3    | Profile name didn't match any channels |
| 4    | Partial success — some channels toggled, some failed |

## Logging

Single-line JSON events per run at `~/Library/Logs/restream-profile/toggle.log` (rotates at 10 MB, 3 backups).

## Keychain entries

| Service | Account | Content |
| --- | --- | --- |
| `com.restream-profile` | `client` | `{client_id, client_secret}` |
| `com.restream-profile` | `tokens` | `{access_token, refresh_token, access_expires_at}` |
| `com.restream-profile` | `last-state` | Last `--profile` run summary |

Inspect with:

```bash
security find-generic-password -s com.restream-profile -a tokens -w
```

## Restream API endpoints used

| Purpose | Method | URL |
| --- | --- | --- |
| Authorize | GET | `https://api.restream.io/login?response_type=code&client_id=...&redirect_uri=...&state=...` |
| Token exchange / refresh | POST | `https://api.restream.io/oauth/token` (Basic-Auth `client_id:client_secret`) |
| List channels | GET | `https://api.restream.io/v2/user/channel/all` |
| Update channel | PATCH | `https://api.restream.io/v2/user/channel/{id}` body `{"active": true|false}` |
| Profile | GET | `https://api.restream.io/v2/user/profile` |

Refresh tokens rotate on every refresh — the script persists the new one back to Keychain automatically.
