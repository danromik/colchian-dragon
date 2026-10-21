# Colchian Dragon

A macOS menu bar app (Swift, AppKit, no Xcode project) that keeps a MacBook awake with the lid closed,
always or only while a Claude Code session is active. `README.md` is the short public intro;
`docs/guide.md` documents the behavior in detail and must be kept in sync with it.

## Build and run

```sh
make run      # debug build for this Mac, quit the running copy, launch
make dev      # same, with a Dock icon (-showDockIcon YES); clicking it opens Settings
make app      # universal release build → build/Colchian Dragon.app
make install  # release build copied to /Applications
```

There are no tests. Verify changes by running the app. To check that the Mac really stayed awake
with the lid closed, run `scripts/count.sh` in a terminal: it prints a gap if the Mac slept.

Always quit the app gracefully (the Makefile does). It sets the system-wide `SleepDisabled` setting
and restores it on quit, so killing it leaves sleep disabled until the next launch or
`sudo pmset -a disablesleep 0`.

## Layout

- `Sources/Colchian/`: the whole app, one Swift package target.
  - `AppDelegate`: owns the state; `reconcile()` decides whether sleep should be disabled
    (mode, active Claude sessions, overheating) and applies it.
  - `PowerManager` / `PrivilegedSetup`: `pmset` calls and the sudoers rule in `/etc/sudoers.d/colchian`
    that allows exactly three `pmset` commands without a password.
  - `ClaudeHookInstaller` / `ClaudeTurnMonitor`: the `colchian-hook` script (embedded as a string and
    rewritten at every launch), the hooks in each Claude config dir's `settings.json`, and the marker
    files in `~/Library/Application Support/Colchian/turns/` plus a Darwin notification.
  - `ThermalMonitor`: thermal state (decides overheating) and temperatures via private IOKit HID APIs
    (display only).
  - `StatusMenu`, `MenuViews`, `Tooltip`, `ModeGuide`, `ModeIllustration`, `MenuBarIcon`, `Drawing`: the
    menu, built from custom `MenuItemView`s that draw their own hover state. `MenuAnimator` ticks them
    every frame while the menu is open. Tooltips and the mode guide are separate windows because
    native tooltips don't work reliably inside menus.
  - `AboutView` + `AboutDesigns/GildedEngraving.swift`: the animated About panel, drawn into an
    offscreen bitmap for performance (see the comment in `AboutView`).
  - `Settings` / `SettingsWindow`: UserDefaults-backed preferences and the SwiftUI Settings panel.
- `Resources/Info.plist`: bundle ID, version, copyright.
- `scripts/`: `build-app.sh` (used by the Makefile), `notarize.sh`, `count.sh`.
- `Archive/` (git-ignored, local only): alternative About designs and icons that aren't built; see
  `Archive/AboutDesigns/README.md`.
- `assets/`: images for the README.

## Notes

- The bundle ID `com.danromik.colchian-dragon` also appears in the `Makefile` and in
  `ClaudeTurnMonitor.notificationName`; change all three together.
- Any setting can be overridden at launch: `open "build/Colchian Dragon.app" --args -key value`.
- Code style: `///` doc comments on types and non-obvious members, explaining *why* in plain sentences.
