# Verified implementation findings

## OBS Custom Browser Docks on macOS

### Failure mode

Opening OBS's **Docks** menu through `click menu bar item "Docks"` creates a modal menu that captures mouse and keyboard input. Reopening it once per configured dock—or allowing overlapping processes to do so—produces rapid menu flicker and can leave OBS apparently frozen even though the OBS process itself is healthy.

An AppleScript command returning after `click menu item ...` is not evidence that the dock opened. The failed implementation counted requested clicks and logged success even when the menu remained open and the dock stayed hidden.

### Correct Accessibility action

OBS exposes its dock menu hierarchy through Accessibility while the **Docks** menu is closed. Each custom dock menu item advertises `AXPress`, `AXPick`, and `AXCancel` actions.

- Apple's `AXPress` action activates the item; use it to toggle a dock.
- `AXPick` only selects a menu item and is not the correct activation action.
- Read `AXMenuItemMarkChar` to determine whether a dock is visible. A missing or empty mark means hidden; a non-empty mark means visible.
- Invoke `AXPress` directly on the hidden menu item without clicking the parent menu bar item. This does not open the menu, change the foreground application, or require a keystroke.
- Re-read `AXMenuItemMarkChar` after the press. Only report success when the checkmark appears.

### Safety contract

- Target only the explicitly requested dock titles. Do not iterate over every entry from OBS `user.ini`.
- Serialize invocations with a cross-process PID lock. An overlapping invocation must skip its UI work rather than wait and replay it later.
- Never retry a failed Accessibility press in the same invocation.
- If the Docks menu was already open, perform one `AXCancel`, then verify the menu bar item's `AXSelected` value is false.
- Do not quit or restart OBS while it is recording or streaming merely to recover from a stuck menu.
- During debugging, disable the trigger before running live experiments. Kill the responsible switcher/`osascript` process, cancel the menu once, and keep further diagnosis read-only until a new mechanism is ready.
- A successful test must verify the requested dock checkmarks, `AXSelected=false`, unchanged foreground application, released lock, and no lingering automation process.

### Verified result

The standalone `restore-obs-browser-docks` command was tested by hiding both default targets through direct closed-menu actions and invoking the command once. It restored both checkmarks, left the Docks menu closed, preserved the foreground application, released its lock, and left no automation process running.

OBScene runs profile commands through a login shell, so the intended composition is:

```sh
restream-channel-switch --alias NAME && restore-obs-browser-docks
```

The dock action remains a separate command so a Restream switch cannot silently acquire UI-automation behavior.

### Diagnostics

Daily NDJSON logs live in `~/Library/Logs/restore-obs-browser-docks/`. Each session records invocation, lock acquisition or skip, and the verified automation result. Files older than approximately seven days are removed on a later invocation.
