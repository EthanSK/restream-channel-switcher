# restream-channel-switcher

A pure-bash CLI that toggles your [Restream.io](https://restream.io) streaming destinations on/off in one shot. You define **aliases** (labels like `reeethan`, `3000ad`, `main`) once via an interactive setup, multi-select which Restream channels belong to each alias, and from then on `--alias reeethan` enables every channel in that alias and disables everything else.

Designed to be fired from a scene-switch hook (e.g. [OBScene](https://github.com/EthanSK/OBScene)) so switching scenes automatically flips which Restream destinations go live.

Why bash: no Python, no runtime, no virtualenv — just standard Unix tools. macOS uses `security` for the Keychain; adapt the three `kc_*` functions for other platforms if needed.

## Why aliases (and not channel-name matching)

Channel-name substring matching looks tempting but breaks the moment you have more than one channel with the same display name on different platforms — e.g. three "REEEthan" entries (YouTube, Twitch, Rumble). v2.1 dropped substring/`--enable`/`--disable` entirely. Aliases bind to **channel IDs**, so they're unambiguous regardless of how you name your channels.

## Dependencies

- `bash` 3.2+ (works on the stock macOS bash; bash 4+ gives a snappier arrow-key response in the picker)
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

### 2. Map channels to aliases (`--setup`)

```bash
restream-channel-switch --setup
```

This prompts you for an alias name and then launches an interactive picker listing every Restream channel on your account — sorted by platform, with full platform ID + display name + channel ID so you can disambiguate channels that share a display name (e.g. multiple "REEEthan" entries on different platforms). Space-toggle each channel into the alias. When you're done, save and you'll be asked whether to add another alias.

```
RESTREAM ALIAS: reeethan                              3 of 13 selected

Up/Dn or j/k  move   Space  toggle   Enter/s  save & exit   n  new alias
d  delete this alias    q/Esc  save & exit    Ctrl-C  cancel

  SEL PLATFORM       CHANNEL                          ID           ON
> [x] 1              3000AD_Music                     12192115     off
  [ ] 1              REEEthan_YT                      11358207     off
  [x] 5              3000AD                           12192073     off
  [ ] 5              REEethan                         16189011     ON
  [x] 37             3000ad                           15630272     off
  [ ] 37             REEEthan                         15629439     off
  ...
```

Key bindings:

| Key | Action |
| --- | --- |
| `↑`/`↓` or `k`/`j` | Move the cursor |
| `g` / `G` | Jump to top / bottom |
| `Space` | Toggle the current channel in/out of this alias |
| `Enter` or `s` | Save this alias and exit |
| `n` | Save this alias and immediately start a new one |
| `d` | Delete this alias entirely (with confirmation) |
| `q` or `Esc` | Save and exit |
| `Ctrl-C` | Cancel without saving |

Top of screen shows the alias name + "X of Y selected" so you always know exactly what you're editing.

### Editing a single alias

If you just want to tweak one alias without going through the whole flow:

```bash
restream-channel-switch --add-alias reeethan
```

`--add-alias` opens the picker scoped to that alias (creates it if it doesn't exist), saves on exit, and returns to the shell.

Re-run `--setup` or `--add-alias` any time you add/remove Restream channels or want to edit alias memberships.

## Usage

```bash
restream-channel-switch --list                       # all channels + on/off state, sorted by platform
restream-channel-switch --aliases                    # list defined aliases + channel counts
restream-channel-switch --alias reeethan             # enable channels in alias "reeethan", disable everything else
restream-channel-switch --alias reeethan --dry-run   # preview, no API writes
restream-channel-switch --add-alias reeethan        # open picker for one alias only
restream-channel-switch --status                     # user info + last toggle + current state
restream-channel-switch --reset-creds                # wipe all keychain entries
restream-channel-switch --help
```

After a real `--alias` run, the CLI now re-fetches Restream channel state, verifies that every alias channel is on and every non-alias channel is off, then re-applies only mismatched channels up to 2 times before returning exit code 4. Tune this with `RESTREAM_VERIFY_RETRIES` and `RESTREAM_VERIFY_SLEEP_SECONDS` if Restream is slow to settle.

### Network retry on transient failures

Token refresh and every API call are wrapped in a retry loop that retries on curl-level failures (DNS resolution, connection refused, TLS handshake) and on HTTP status `000` (no response). This matters when the script is fired by an OBScene USB-plug-in / display-attach trigger right after wake-from-sleep — the network stack is often still coming up at that exact moment, and a one-shot curl would silently fail with `Could not resolve host`, leaving the channel switch a no-op.

Defaults: 4 retries, 2-second initial backoff (exponential — 2s, 4s, 8s, 16s), 15-second connect timeout. Tune via:

| Env var | Default | Meaning |
| --- | --- | --- |
| `RESTREAM_NET_RETRIES`         | 4  | Number of retries beyond the initial attempt |
| `RESTREAM_NET_SLEEP_SECONDS`   | 2  | Initial backoff in seconds (doubles each retry) |
| `RESTREAM_NET_TIMEOUT_SECONDS` | 15 | curl `--connect-timeout` (max-time is 2x) |

Auth errors (4xx) and server errors (5xx) are not retried by this layer; they're surfaced via the existing exit codes (1 / 2 / 4).

Network failures are logged as structured NDJSON events (`net-retry-exhausted`, `api-net-fail`, `token-post-net-fail`) in `~/Library/Logs/restream-channel-switch/toggle.log`, so post-mortems on a silent USB-trigger run are straightforward.

## OBScene integration (intended use case)

[OBScene](https://github.com/EthanSK/OBScene) exposes a per-profile "Run Script" field. Point it at this CLI with an `--alias` argument and OBScene will fire it on profile activation:

```
/Users/you/.local/bin/restream-channel-switch --alias reeethan
```

No daemons, no USB watchers, no launchd plists — OBScene handles the trigger; this script handles the API call. That's the whole loop.

## Exit codes

| Code | Meaning |
| ---- | ------- |
| 0    | Success |
| 1    | Auth error (tokens bad / expired / revoked — re-run `--auth`) |
| 2    | Network / API error |
| 3    | Alias matched zero channels (run `--setup` to assign some) |
| 4    | Partial success — some channels toggled, some failed, or final verification still mismatched after retries |
| 5    | No alias mapping exists yet (run `--setup`) |

## Keychain entries

| Service | Account | Content |
| --- | --- | --- |
| `com.restream-profile` | `client`           | `{client_id, client_secret}` |
| `com.restream-profile` | `tokens`           | `{access_token, refresh_token, access_expires_at}` |
| `com.restream-profile` | `channel-aliases`  | `{channel_aliases: { "<channel_id>": ["alias1","alias2"], ... }}` |
| `com.restream-profile` | `last-state`       | Last `--alias` run summary |

> **Note:** the Keychain service name is `com.restream-profile` (not `com.restream-channel-switch`) for continuity with v1. Renaming it would invalidate every existing install's auth, which isn't worth it. The CLI binary + repo are renamed; the service name is a deliberately-preserved legacy string.

Inspect an entry with:

```bash
security find-generic-password -s com.restream-profile -a channel-aliases -w | jq .
```

## Logging

Single-line JSON events per run at `~/Library/Logs/restream-channel-switch/toggle.log`. Rotates manually — when the file exceeds 10 MB it's renamed to `toggle.log.1`. The saved `last-state` keychain record includes `verified` plus any final `mismatches`, so failures clearly show which destinations did not reach the expected on/off state.

Notable event types:

- `alias` — alias applied (`result: ok|partial`, `verified: true|false`)
- `refresh` — token refresh (`result: ok|fail`)
- `api-error` — API call returned a non-2xx final status after retries
- `net-retry-recovered` — a transient network failure recovered after one or more retries (`attempts: N`)
- `net-retry-exhausted` — a network failure exhausted all retries (`attempts: N`)
- `api-net-fail` — API call failed at the network layer after retries (`method`, `path`, `attempts`, `curl_exit`, `status`)
- `token-post-net-fail` — token endpoint failed at the network layer after retries
- `token-post-http-fail` — token endpoint returned a non-2xx HTTP status

When debugging a silent USB-trigger no-op, grep for `api-net-fail` / `token-post-net-fail` first.

## Migrating from the "flags" era (v2.0 → v2.1)

v2.0 called these "flags" and stored them under keychain account `channel-flags`. v2.1 renames the concept to "aliases" (clearer; "flag" was overloaded with CLI-flag and feature-flag connotations) and stores them under `channel-aliases`.

The migration is automatic and one-shot:

1. Pull v2.1 (`git pull` in this repo).
2. Run any command that reads the alias map (e.g. `--aliases`, `--alias NAME`, `--setup`).
3. The script detects the legacy `channel-flags` keychain entry, copies the data into the new `channel-aliases` account (renaming the wrapping JSON key from `channel_flags` → `channel_aliases`), and continues. The old entry is left in place as a safety net; `--reset-creds` clears both.

CLI changes you'll see:

- `--flags` → `--aliases` (old name still works for one release with a deprecation warning).
- `--flag NAME` → `--alias NAME` (old name still works for one release with a deprecation warning).
- `--enable NAME` / `--disable NAME` were **removed**. Substring matching of channel names was too imprecise once you had multiple channels with the same display name on different platforms. Use `--add-alias <name>` to define explicit channel-ID-based groups instead.
- New: `--add-alias NAME` opens the picker for a single alias.

## Migrating from v1 (`restream-profile-switcher`)

If you were using the original `--profile NAME` substring-matcher:

1. Pull the rename: `cd ~/Projects/restream-profile-switcher && git remote set-url origin https://github.com/EthanSK/restream-channel-switcher.git && cd .. && mv restream-profile-switcher restream-channel-switcher && cd restream-channel-switcher && git pull`.
2. Update the symlink: `ln -sf ~/Projects/restream-channel-switcher/restream-channel-switch.sh ~/.local/bin/restream-channel-switch` and optionally `ln -s ~/.local/bin/restream-channel-switch ~/.local/bin/restream-profile` for backwards compat.
3. Your existing OAuth tokens still work (same Keychain entries).
4. Run `restream-channel-switch --setup` to create explicit alias-to-channel mappings.
5. Replace `--profile reeethan` with `--alias reeethan` in any callers (OBScene, scripts, etc.). The CLI will error clearly if `--profile` is passed.

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
