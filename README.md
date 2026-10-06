# Sweep

A simple macOS menu bar app that collects everyday utilities. Every feature is a self-contained module, **off by default**, enabled with one toggle. Nothing runs, listens, or asks for permissions until you turn a feature on.

**Signature feature — one-click Sweep:** a single click hides the messy desktop: all running apps *and* all desktop files disappear. A second click restores everything exactly as it was. Files never move and apps are hidden, never quit — zero data risk.

100% local: no network calls, no analytics, no accounts.

## Features (v1)

| Feature | What it does |
|---|---|
| **Desktop Sweep** | Hides every desktop icon (Finder `CreateDesktop` toggle + graceful Finder relaunch). Files never move. |
| **App Sweep** | Hides all running apps, snapshots them to JSON, restores them later and refocuses the app you were using. Per-feature exclusion list. |
| **Sweep All** | The panel's main button + a global shortcut run both sweeps together. The menu bar icon shows the swept state. |
| **Keep Awake** | IOKit power assertion with 15m/30m/1h/2h/indefinite durations, optional display sleep, battery cut-off. |
| **System Glance** | Live CPU / memory / disk card (updates only while the panel is open) and optional CPU % menu bar readout. |

## Using it

- **Left-click** the menu bar icon → the panel with your enabled features.
- **Right-click** → Settings…, Quit.
- Settings → **General**: launch at login, the global Sweep shortcut.
- Settings → **Features**: every module with an on/off toggle (and per-feature options behind the slider icon).
- If Sweep quits or crashes while swept, the next launch offers to restore.

## Requirements

- macOS 14 Sonoma or later
- Not sandboxed (direct distribution) — required for Finder/app control

## Building

```sh
xcodebuild -project Sweep.xcodeproj -scheme Sweep -configuration Debug build
```

Or open `Sweep.xcodeproj` in Xcode and run.

## Release / distribution

```sh
# Unsigned dmg for local testing:
scripts/make-dmg.sh

# Developer ID signed + notarized dmg:
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/make-dmg.sh
```

The app icon is generated with `swift scripts/generate-icon.swift Sweep/Assets.xcassets/AppIcon.appiconset`.

## Architecture

Every feature implements the `FeatureModule` protocol (id, name, summary, required permissions, activate/deactivate) and is owned by a central `FeatureRegistry`. A disabled module consumes zero resources — no timers, no observers. See `Sweep/Core/FeatureModule.swift`.
