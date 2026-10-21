# Colchian Dragon Guide

*Named for the sleepless dragon that guarded the Golden Fleece.*

Colchian Dragon is a macOS menu bar utility that keeps a MacBook awake with the lid closed — either
always, or only while a [Claude Code](https://claude.com/claude-code) session is active,
so you can close the laptop without interrupting a running session.

## The menu

Clicking the menu bar icon opens a menu with:

- **A status dashboard:** how many Claude Code sessions are open and how many are active,
  and the thermal state with the CPU, battery and SSD temperatures. Either box can be hidden under **Dashboard** in Settings.
- **The three modes:**
  - **No override:** the Mac sleeps when the lid closes.
  - **Stay Awake (Always):** lid-close sleep is disabled.
  - **Stay Awake (Claude Code):** lid-close sleep is disabled only while a Claude Code session is
    active.

  Hover over a mode to see an animation of what it does, or over the ? button next to the Sleep
  Override Mode heading for an explanation of all three. Clicking a mode keeps the menu open, so you can see the
  change.
- A ⚙︎ button that opens the Settings window, **About**, which expands the menu to tell the story of
  the Colchian dragon (with the version and copyright), a **website** link to the GitHub repository,
  and **Quit**.

The menu bar icon is the selected mode's icon from the menu:

| Menu bar icon | Mode |
|---|---|
| A laptop with the dragon's eye over its screen's corner | **No override** |
| The dragon's eye | **Stay Awake (Always)** |
| The dragon's eye with Claude Code's asterisk | **Stay Awake (Claude Code)** |

Hover over the icon to see the current status, such as whether a Claude Code session is keeping the Mac
awake, or whether it got too hot and sleep has been re-enabled until it cools down.

- Colchian Dragon remembers the selected mode when it relaunches.
- When sleep is re-enabled while the lid is already closed (the last session became inactive, or the Mac got
  too hot), Colchian Dragon puts the Mac to sleep right away.
- Quitting Colchian Dragon always restores normal sleep.

## How it works

### Disabling lid-close sleep

`caffeinate` and IOKit power assertions can't keep a laptop awake with the lid closed (unless an
external display is attached). Only the system-wide `SleepDisabled` setting can, via
`pmset -a disablesleep 1`, and that requires root access.

To avoid having to ask you to enter your password each time you adjust the mode, Colchian Dragon installs a sudoers rule
in `/etc/sudoers.d/colchian`. The rule lets *your account only* run exactly these three commands
as root without a password:

```
pmset -a disablesleep 0
pmset -a disablesleep 1
pmset sleepnow
```

Colchian Dragon offers to install the rule the first time you choose a Stay Awake mode, and you can install
or remove it under **Passwordless Control** in Settings. The rule is checked with `visudo` before it
is installed. You can also remove it with `sudo rm /etc/sudoers.d/colchian`.

### Claude Code sessions

Choosing **Stay Awake (Claude Code)** offers to add hooks to Claude Code's `settings.json`.
Colchian Dragon finds `~/.claude` and any `~/.claude-*` directories (used with `CLAUDE_CONFIG_DIR`). You can
turn the hooks on or off for each one under **Claude Code Hooks** in the app's Settings window.
The first edit saves a backup as `settings.json.colchian-backup`.

The hooks call `~/Library/Application Support/Colchian/colchian-hook`, which keeps one marker
file per session in `…/Colchian/turns/` and notifies the app at once (a Darwin notification):

| Hook event | Action |
|---|---|
| `UserPromptSubmit` | session active (a turn started) |
| `PreToolUse`, `PostToolUse` | session active (a tool call, also by a background agent) |
| `SubagentStop` | still active (heartbeat) |
| `Stop` | session inactive, unless background tasks are still running |
| `StopFailure`, `SessionEnd` | session inactive |

Several sessions can run at once; sleep stays disabled until the last one becomes inactive.

Background agents, workflows, shell commands and monitors keep running after the turn that started
them ends. `Stop` lists the ones still running, and while there are any the session counts as
active. When they finish they report back by starting a new turn, and the session is done when a
turn ends with none left. A session whose `claude` process has exited is done too.

Claude Code doesn't run `Stop` hooks when you interrupt a turn (Esc). A session with no hook activity
for 30 minutes is therefore treated as finished. Background shell commands don't run hooks while
they work, so this limit also applies to them. You can change it:

```sh
defaults write com.danromik.colchian-dragon staleTurnMinutes -int 60
```

Claude Code reloads its settings files while it runs, so sessions that are already running pick
up hook changes without a restart. A session that is already active when you turn hooks on is
tracked from its next tool call on.

### Overheating protection

Colchian Dragon watches the macOS thermal state (`ProcessInfo.thermalState`), the same signal macOS uses
to throttle the CPU. If the state reaches the **Thermal Safety Limit** set in Settings (default
*Serious*), Colchian Dragon
re-enables sleep and shows a flame in the dashboard's thermal box, and if it was keeping the Mac
awake, it sends a notification. If the lid is closed, the Mac goes to sleep.
Lid-close sleep is disabled again only after the Mac cools well below the limit (back to
*Nominal* when the limit is *Serious*).

The dashboard also shows temperatures in °C: the hottest of the CPU die's sensors, the battery and
the SSD. macOS has no public API for them on Apple Silicon, so Colchian Dragon reads them through
IOKit's private HID event system. They're for display only; the safety limit uses the thermal state.

## Install

Download `Colchian-Dragon.zip` from [Releases](https://github.com/danromik/colchian-dragon/releases), unzip it, move `Colchian Dragon.app` to `/Applications` and open it.
Turn on **Launch Colchian Dragon at Login** in Settings to keep it running.

## Build from source

Requires macOS 13+ and Xcode 15+ (or the Xcode command line tools).

```sh
git clone https://github.com/danromik/colchian-dragon.git && cd colchian-dragon
make install      # universal release build, ad-hoc signed, copied to /Applications
```

Other targets:

```sh
make run          # debug build, launch
make dev          # debug build, launch with a Dock icon (handy while developing)
make app          # build only → build/Colchian Dragon.app
make clean
```

Colchian Dragon has no Dock icon. With `make dev`, while the Dock icon is shown, clicking it opens
Settings.

### Signed and notarized release

You need a **Developer ID Application** certificate (an *Apple Development* certificate is not
enough for distribution).

```sh
# one time: store notarization credentials in the keychain
xcrun notarytool store-credentials colchian-notary \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

make release SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make notarize     # → build/Colchian-Dragon.zip, notarized and stapled
```

## Uninstall

1. In Colchian Dragon Settings, turn off every entry under **Claude Code Hooks**, click **Remove…** under
   **Passwordless Control**, and turn off **Launch Colchian Dragon at Login**.
2. Quit Colchian Dragon and delete `Colchian Dragon.app`.
3. Delete `~/Library/Application Support/Colchian`.
4. Optionally, delete the backups Colchian Dragon made of your Claude Code settings
   (`settings.json.colchian-backup` in `~/.claude` and any `~/.claude-*` directories), and its
   preferences:

   ```sh
   defaults delete com.danromik.colchian-dragon
   ```

## Caveats

- A Mac running with its lid closed inside a bag can get hot. The thermal guard is a safety net,
  not a substitute for ventilation.
- While sleep is disabled, the battery drains with the lid closed.
- `SleepDisabled` is a system-wide setting. If Colchian Dragon is force-killed while it is set, the
  setting stays on until Colchian Dragon launches again (which corrects it) or you run
  `sudo pmset -a disablesleep 0`.
