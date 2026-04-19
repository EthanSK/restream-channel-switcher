# restream-channel-switcher

A pure-bash CLI that toggles your [Restream.io](https://restream.io) streaming destinations on/off in one shot. You define **flags** (labels like `wreathen`, `3000ad`, `main`) once via an interactive setup, map each Restream channel to zero-or-more flags, and from then on `--flag wreathen` enables every channel in that flag and disables everything else.

Designed to be fired from a scene-switch hook (e.g. [OBScene](https://github.com/EthanSK/OBScene)) so switching scenes automatically flips which Restream destinations go live.

Why bash: no Python, no runtime, no virtualenv — just standard Unix tools. macOS uses `security` for the Keychain; adapt the three `kc_*` functions for other platforms if needed.

## Dependencies

- `bash` 3.2+ (works on the stock macOS bash; bash 4+ gives a snappier arrow-key response in `--setup`)
- `curl`
- `jq` — `brew install jq`
- `security` — macOS Keychain CLI (ships with macOS)
- `nc` — one-shot OAuth callback listener (ships with macOS)
- `openssl` — for the OAuth `state` nonce (ships with macOS)
- `open` — to launch the browser during `--auth` (macOS; on Linux substitute `xdg-open`)

## Install

```bash
git clone https://github.com/EthanSK/restream-channel-switcher.git ~/Projects/restream-channel-switcher
chmod +x ~/Projects/restream-channel-switcher/restream-channel-switch.sh
mkdir -p ~/.local/bin
ln -s ~/Projects/restream-channel-switcher/restream-channel-switch.sh ~/.local/bin/restream-channel-switch
# Optional compat alias for anyone upgrading from v1:
ln -s ~/.local/bin/restream-channel-switch ~/.local/bin/restream-profile
```

Make sure `~/.local/bin` is on your `$PATH`.

## One-time setup

Two steps, run once.

### 1. OAuth (`--auth`)

1. Go to <https://developers.restream.io/apps> and create a new application.
2. Set the redirect URI to exactly: `http://localhost:8976/callback`
3. Enable the scopes: `profile.read`, `channels.read`, `channels.write`
4. Copy the `Client ID` and `Client Secret`.

Then run:

```bash
restream-channel-switch --auth
```

The CLI prompts for Client ID + Client Secret (saved to Keychain), opens the Restream authorize page, catches the `?code=...` callback on port 8976, exchanges it for tokens, and persists them.

### 2. Map channels to flags (`--setup`)

```bash
restream-channel-switch --setup
```

This launches an interactive terminal UI listing every Restream channel on your account. You create flags (names are arbitrary — `wreathen`, `3000ad`, `podcast`, `main`, etc.) and space-toggle each channel into the flags it belongs to. A channel can belong to any number of flags.

```
RESTREAM CHANNEL SETUP

Map each channel to one or more flags. A flag is just a label you pick
(e.g. "wreathen", "3000ad", "main"). Later, `--flag <name>` enables
every channel tagged with <name> and disables the rest.

Up/Dn or j/k  move   Space  toggle channel in active flag   Tab  next flag
n  new flag    d  delete active flag    s/q  save & quit    Esc  cancel

  SEL CHANNEL                         ON  PLATFORM    FLAGS
> [x] YouTube (Wreathen)              ON  youtube     wreathen, stream-all
  [ ] Twitch (3000AD)                 off twitch      3000ad, stream-all
  [ ] Facebook Page                   off facebook    (none)
  [x] Rumble (Wreathen backup)        off rumble      wreathen
  ...

─────────────────────────────────────────────────────────────
Active flag: wreathen   (3 of 3 — Tab cycles)
All flags: 3000ad, stream-all, wreathen
```

Key bindings:

| Key | Action |
| --- | --- |
| `↑`/`↓` or `k`/`j` | Move the cursor |
| `g` / `G` | Jump to top / bottom |
| `Space` | Toggle the current channel in/out of the active flag |
| `Tab` | Cycle which flag is currently active |
| `n` | Create a new flag (prompted) |
| `d` | Delete the active flag (removes it from every channel) |
| `s` or `q` | Save and quit |
| `Esc` | Cancel without saving |

Re-run `--setup` any time you add/remove Restream channels or want to edit flag memberships.

## Usage

```bash
restream-channel-switch --list                                    # all channels + on/off state
restream-channel-switch --flags                                   # list defined flags + channel counts
restream-channel-switch --flag wreathen                           # enable channels tagged "wreathen", disable others
restream-channel-switch --flag wreathen --dry-run                 # preview, no API writes
restream-channel-switch --enable "YouTube" --disable "Twitch"     # fine-grained, substring match
restream-channel-switch --status                                  # user info + last toggle + current state
restream-channel-switch --reset-creds                             # wipe all keychain entries
restream-channel-switch --help
```

## OBScene integration (intended use case)

[OBScene](https://github.com/EthanSK/OBScene) exposes a per-profile "Run Script" field. Point it at this CLI with a `--flag` argument and OBScene will fire it on profile activation:

```
/Users/you/.local/bin/restream-channel-switch --flag wreathen
```

No daemons, no USB watchers, no launchd plists — OBScene handles the trigger; this script handles the API call. That's the whole loop.

## Exit codes

| Code | Meaning |
| ---- | ------- |
| 0    | Success |
| 1    | Auth error (tokens bad / expired / revoked — re-run `--auth`) |
| 2    | Network / API error |
| 3    | Flag matched zero channels (run `--setup` to assign some) |
| 4    | Partial success — some channels toggled, some failed |
| 5    | No flag mapping exists yet (run `--setup`) |

## Keychain entries

| Service | Account | Content |
| --- | --- | --- |
| `com.restream-profile` | `client`         | `{client_id, client_secret}` |
| `com.restream-profile` | `tokens`         | `{access_token, refresh_token, access_expires_at}` |
| `com.restream-profile` | `channel-flags`  | `{channel_flags: { "<channel_id>": ["flag1","flag2"], ... }}` |
| `com.restream-profile` | `last-state`     | Last `--flag` run summary |

> **Note:** the Keychain service name is `com.restream-profile` (not `com.restream-channel-switch`) for continuity with v1. Renaming it would invalidate every existing install's auth, which isn't worth it. The CLI binary + repo are renamed; the service name is a deliberately-preserved legacy string.

Inspect an entry with:

```bash
security find-generic-password -s com.restream-profile -a channel-flags -w | jq .
```

## Logging

Single-line JSON events per run at `~/Library/Logs/restream-channel-switch/toggle.log`. Rotates manually — when the file exceeds 10 MB it's renamed to `toggle.log.1`.

## Migrating from v1 (`restream-profile-switcher`)

If you were using the old `--profile NAME` substring-matcher:

1. Pull the rename: `cd ~/Projects/restream-profile-switcher && git remote set-url origin https://github.com/EthanSK/restream-channel-switcher.git && cd .. && mv restream-profile-switcher restream-channel-switcher && cd restream-channel-switcher && git pull`.
2. Update the symlink: `ln -sf ~/Projects/restream-channel-switcher/restream-channel-switch.sh ~/.local/bin/restream-channel-switch` and optionally `ln -s ~/.local/bin/restream-channel-switch ~/.local/bin/restream-profile` for backwards compat.
3. Your existing OAuth tokens still work (same Keychain entries).
4. Run `restream-channel-switch --setup` to create explicit flag-to-channel mappings (v1's implicit substring matching is gone).
5. Replace `--profile wreathen` with `--flag wreathen` in any callers (OBScene, scripts, etc.). The CLI will error clearly if `--profile` is passed.

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
