# OBS + Restream automation wiring

This doc describes how Ethan's machine automatically flips OBS profile + Restream
destinations between **Wreathen** (streaming rig / dev-stream mode) and
**3000AD** (music / DJ mode) based on hardware events — no manual clicks.

---

## How the automation works

```
                    ┌─────────────────────────────────────────┐
                    │   HARDWARE EVENT                        │
                    │   ─ USB device attach/detach            │
                    │   ─ Display (re)connect                 │
                    └────────────────┬────────────────────────┘
                                     │
                                     ▼
                    ┌─────────────────────────────────────────┐
                    │   USB / Display watcher                 │
                    │   (native IOKit binary, launchd-managed)│
                    │   native/usb-watcher/main.swift         │
                    └────────────────┬────────────────────────┘
                                     │ matches Vendor/Product ID
                                     ▼
                    ┌─────────────────────────────────────────┐
                    │   Exec: restream-profile.py             │
                    │         --profile wreathen|3000ad       │
                    │   (built by Subagent A)                 │
                    └────────────────┬────────────────────────┘
                                     │ talks to
                                     ▼
              ┌──────────────────────┴──────────────────────┐
              ▼                                             ▼
   ┌────────────────────────┐                 ┌──────────────────────────┐
   │  Restream API          │                 │  obs-websocket (4455)    │
   │  enable/disable        │                 │  SetCurrentProfile       │
   │  destinations          │                 │  (REEEthan Foundry /     │
   │  per profile           │                 │   3000AD Music)          │
   └────────────────────────┘                 └──────────────────────────┘

Separately, when Ethan manually clicks Profile → X in the OBS UI:

   OBS UI ──(CurrentProfileChanged event)──▶ obs-profile-listener.py ──▶ restream-profile.py
```

Two independent triggers, one CLI.

---

## Wiring instructions (chosen approach: Option A — launchd + Swift IOKit watcher)

**Why A over B/C:** Ethan doesn't have Hammerspoon installed (B would require
installing a new app), and his OBS doesn't have Advanced Scene Switcher
(C requires the plugin). Native Swift + launchd is self-contained, survives
reboots, and works whether or not OBS is running.

### 1. Build the Swift USB watcher

```bash
cd ~/Projects/restream-profile-switcher/native/usb-watcher
swiftc -O -o usb-watcher main.swift \
    -framework IOKit -framework CoreFoundation
```

This produces `./usb-watcher`. It reads its config from
`~/.config/restream-profile/watcher.json`:

```json
{
  "restream_profile_cli": "/Users/ethansarif-kattan/Projects/restream-profile-switcher/restream-profile.py",
  "triggers": [
    {
      "on": "usb_attach",
      "vendor_id": "0x????",
      "product_id": "0x????",
      "comment": "REPLACE: Ethan's stream-rig USB device (capture card, mic interface, etc.)",
      "profile": "wreathen"
    },
    {
      "on": "display_attach",
      "comment": "Any external display attach triggers 3000AD",
      "profile": "3000ad"
    }
  ]
}
```

See "USB device matcher" section below for how to fill in the IDs.

### 2. Install the LaunchAgent

```bash
cp launchd/com.ethansk.restream-profile-auto.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.ethansk.restream-profile-auto.plist
```

The agent:
- runs `usb-watcher` at login (`RunAtLoad=true`)
- restarts it automatically if it crashes (`KeepAlive=true`)
- logs to `~/Library/Logs/restream-profile-auto.log`

### 3. Install the OBS profile-change listener (always runs)

This is the second half: when Ethan **manually** clicks Profile → X in OBS,
Restream destinations update to match.

```bash
pip3 install --user obsws-python
cp launchd/com.ethansk.obs-profile-listener.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.ethansk.obs-profile-listener.plist
```

The listener:
- connects to `ws://127.0.0.1:4455` with the password from
  `~/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json`
- subscribes to the `CurrentProfileChanged` event
- on each event, execs `restream-profile.py --profile <new-name>`
- reconnects on disconnect

### 4. Verify

```bash
launchctl list | grep ethansk
tail -f ~/Library/Logs/restream-profile-auto.log
tail -f ~/Library/Logs/obs-profile-listener.log
```

Plug/unplug the target USB device. You should see a log line, then OBS's
current profile should flip, and Restream destinations should update within
a second or two.

---

## USB device matcher

To fill in `vendor_id` / `product_id` in `watcher.json`:

1. **Before plugging** the Wreathen device, list what's already attached:
   ```bash
   ioreg -p IOUSB -l | grep -E '"USB Product Name"|"idVendor"|"idProduct"' > /tmp/before.txt
   ```
2. **Plug in** the device.
3. List again:
   ```bash
   ioreg -p IOUSB -l | grep -E '"USB Product Name"|"idVendor"|"idProduct"' > /tmp/after.txt
   diff /tmp/before.txt /tmp/after.txt
   ```
4. The new block tells you the product name + decimal vendor/product IDs.
   Convert decimal → hex for the config:
   ```bash
   python3 -c 'print(hex(8644))'   # 0x21c4 (example)
   ```
5. Copy hex values into `vendor_id` / `product_id`. Include the `0x` prefix.

Alternative: `system_profiler SPUSBDataType` shows IDs as hex already under
"Vendor ID" / "Product ID" fields, but the output is verbose.

> **Heads up:** some USB hubs expose the device behind an internal hub. If the
> watcher doesn't fire, also try the parent hub's IDs, or match on
> `USB Product Name` via a substring (feature not yet implemented; file an
> issue to add `product_name_contains` matching).

### Display matcher

Display events use `CGDisplayRegisterReconfigurationCallback`. The watcher
simply fires `display_attach` / `display_detach` whenever the active display
count changes. If Ethan wants to only trigger on a *specific* monitor (not
just "any external"), we need to match on the display's
`CGDisplaySerialNumber` or EDID vendor — file an issue to extend the config.

Currently the internal MacBook retina is always present. Any *additional*
display (Dell, LG, CalDigit hub downstream, etc.) triggers `display_attach`.

---

## Debugging

### Manually fire the trigger (bypass the watcher)

```bash
~/Projects/restream-profile-switcher/restream-profile.py --profile wreathen
~/Projects/restream-profile-switcher/restream-profile.py --profile 3000ad
```

### Tail logs

```bash
# USB/display watcher
tail -f ~/Library/Logs/restream-profile-auto.log

# OBS profile listener (CurrentProfileChanged events)
tail -f ~/Library/Logs/obs-profile-listener.log

# Launchd stdout/stderr (if plist misconfigured)
log stream --predicate 'subsystem == "com.apple.xpc.launchd"' --info | grep ethansk
```

### Check obs-websocket is reachable

```bash
# Port open?
lsof -iTCP:4455 -sTCP:LISTEN

# Password (auth_required=true) lives at:
cat "$HOME/Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json"
```

Current values (as of investigation): port **4455**, auth **required**,
password in `config.json` under `server_password`.

### Force a profile change in OBS to test the listener

In OBS: Profile menu → pick the other profile. The listener should log
`CurrentProfileChanged -> <name>` and fire `restream-profile.py`.

### Reload the LaunchAgents after editing

```bash
launchctl unload ~/Library/LaunchAgents/com.ethansk.restream-profile-auto.plist
launchctl load   ~/Library/LaunchAgents/com.ethansk.restream-profile-auto.plist
launchctl unload ~/Library/LaunchAgents/com.ethansk.obs-profile-listener.plist
launchctl load   ~/Library/LaunchAgents/com.ethansk.obs-profile-listener.plist
```

---

## Alternative approaches

### Option B — Hammerspoon

Hammerspoon has native `hs.usb.watcher` and `hs.screen.watcher` Lua APIs. A
~20-line `init.lua` snippet could bind USB attach → shell out to
`restream-profile.py` + HTTP to obs-websocket. Pro: easy to edit, no compile
step. Con: requires installing Hammerspoon (`brew install --cask hammerspoon`)
and granting it Accessibility permissions. If Ethan ever installs Hammerspoon
for other reasons, we can rewrite `native/usb-watcher/main.swift` as
`~/.hammerspoon/restream-profile-auto.lua` without touching the CLI or the
OBS listener.

### Option C — OBS Advanced Scene Switcher plugin

The Advanced Scene Switcher plugin has a "Run" action that can shell out when
conditions are met, including video-capture-device availability. Pro: pure
OBS, visible in OBS UI. Cons: only runs while OBS is open; hardware detection
is indirect (it only sees things OBS sees — typically video/audio sources, not
arbitrary USB), so a capture card works but a generic USB dongle won't. We'd
also need to install the plugin from
https://github.com/WarmUpTill/SceneSwitcher.

---

## Open questions for Ethan

- **Which USB device** should trigger Wreathen mode? (product name / brand so
  we can read its VID/PID off `ioreg`). At investigation time only a "USB
  Flash Disk" was attached.
- **Which monitor** counts as "plugging into the external setup"? Any
  external, or a specific one (e.g. the LG/Dell ultrawide)? The current
  default fires on any external-display attach.
- **Restream destination names / IDs** — the CLI (Subagent A's file)
  presumably needs a mapping from profile → destination set. If you want
  the watcher to pass explicit destination IDs instead of just a profile
  name, say the word and we'll thread them through.
- **OBS profile folder names** are `REEEthan_Foundry` (display name
  "REEEthan Foundry") and `3000AD_Music` (display name "3000AD Music").
  The obs-websocket `SetCurrentProfile` request takes the display name.
  If "Wreathen" is a separate profile that doesn't exist yet, create it
  before wiring up.
