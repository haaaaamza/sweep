# Sweep — Project Documentation

A macOS menu bar app that bundles everyday utilities into one place. Every feature is a self-contained module, **off by default**, enabled with one toggle. Nothing runs, listens, or asks for permissions until you turn a feature on. 100% local — no network calls, no analytics, no accounts.

**Signature feature — one-click Sweep:** one press hides the messy desktop (all desktop files *and* all running apps disappear); a second press restores everything exactly as it was.

- Minimum OS: macOS 14 Sonoma
- Language/UI: Swift + SwiftUI (AppKit lifecycle, `LSUIElement` — no Dock icon)
- Distribution: direct (not sandboxed — required for Finder/app control)

---

## Features

### Desktop Sweep (files)
Hides every icon on the desktop by flipping Finder's `CreateDesktop` preference and relaunching Finder gracefully. **Files never move** — zero data risk.
- State is tracked by the app and persisted, so it survives relaunches.
- Crash safe: if Sweep closes while the desktop is hidden, the next launch offers to restore.
- Finder is relaunched explicitly after the polite quit (macOS only auto-relaunches it after a force-kill).

### App Sweep (apps)
Sweeps every running app with one click and brings the session back with the next.
- **Two modes** (Options → Sweep mode):
  - **Hide** (default): apps are hidden, never quit — restore is instant, nothing can be lost.
  - **Quit** (Later-style): apps are asked to quit *politely* — unsaved work always gets a save dialog; Finder is only hidden, never quit. Saves battery.
- **Restore** unhides running apps and **relaunches quit apps** from their saved bundle paths, then refocuses the app you were using.
- **Session snapshot** saved as JSON (`~/Library/Application Support/Sweep/app-snapshot.json`): bundle IDs, app paths, names, frontmost app, mode, date — so restore works even after Sweep itself relaunches. The panel card shows a summary ("Safari, Notes, +3 more · 5:12 PM").
- **Reopen automatically**: Off / 15 min / 30 min / 1 h / 5 h — after a sweep the session restores itself; the card shows a live countdown with Cancel.
- **Exclusion list**: apps switched ON under "Never hide these apps" are always left alone. Sweep itself is always excluded.
- **Full-screen & split-view windows**: with the Accessibility permission, Sweep takes them out of full screen first (macOS ignores hide for full-screen apps), hides everything, and puts them back into full screen on restore.
- Stubborn apps: hides are verified and retried; as a last resort the app is hidden via the Accessibility `AXHidden` attribute.

### Sweep All
The panel's main button and the global shortcut run both sweeps together; a second press restores both. The menu bar icon switches between outline/filled while swept.

### Keep Awake
Prevents sleep via an IOKit power assertion (no helper tools, no permissions).
- Durations: 15 min / 30 min / 1 h / 2 h / Indefinite, with a live countdown on the card.
- Option to let the display sleep while the Mac stays awake.
- Battery cut-off: auto-stops below a chosen % (default 10%) while on battery.
- The session always ends when Sweep quits — the assertion cannot outlive the app.

### Clipboard History (Flycut-style)
Remembers what you copy — **text and images** — and pastes any of it back, anywhere.
- While enabled, the general pasteboard is polled (0.5 s) for new clippings; disabled = zero resources.
- **The bezel** (signature interaction, like Flycut): press the recorded shortcut (⌘⇧V by default) and a translucent HUD appears showing the newest clipping. Keep the modifiers held and press the shortcut key again (or ← → ↑ ↓) to go back and forth; **release the modifier keys** (or Return) to choose, then ⌘V pastes it. 1–9 jump straight to a clipping. Esc cancels. The bezel is a non-activating key panel, so the app you were using stays frontmost and the paste lands in it.
- **Bezel designs** (Options → Bezel design, 9 to choose from): Refined HUD (default — header, kind badge, thumbnail filmstrip, hints), Flycut Classic (minimal), Card Deck (neighbors peek from the sides), Filmstrip (big thumbnails first), List + Preview (Maccy-style), Bottom Bar (Paste-style shelf at the screen's bottom edge), Compact Pill (one-line capsule near the top), Sidebar (content + metadata rail), and Grid Picker (3×3 board, digits pick & paste instantly). HTML mockups of all nine live in `design/bezel-variations.html`.
- **History**: 10 / 25 / 50 / 100 clippings (default 25), newest first; re-copying moves an entry to the top instead of duplicating it (images deduped by SHA-256).
- **Images**: screenshots and copied images are captured (normalized to PNG, stored in `~/Library/Application Support/Sweep/clipboard-images/`, ≤50 MB each); when there is meaningful text on the pasteboard, the text wins.
- **Panel card**: the 5 most recent clippings (image rows show a thumbnail) — click one to copy it back (checkmark feedback), plus count + Clear.
- **Paste immediately** (off by default): after picking, Sweep simulates ⌘V in the active app — needs the Accessibility permission; without it, picking only copies.
- **Privacy**: content marked transient/concealed (password managers, per nspasteboard.org conventions) is never recorded. "Remember across launches" (on by default) saves the history to `~/Library/Application Support/Sweep/clipboard-history.json`; turning it off deletes the saved files. Text clippings are capped at 100k characters.

### System Glance
Live CPU / memory / disk tiles on the panel. The 2-second sampler runs **only while the panel is open** — zero cost when closed. Optional "CPU 42%" readout next to the menu bar icon (off by default).

### Monitor window
A Vitals-style window (panel footer → **Open Monitor**, or right-click the icon):
- **Overview**: CPU / Memory / Disk tiles + "Busiest right now" (top apps by CPU).
- **CPU / Memory**: one row per app with every helper process folded in — icon, process count, usage bar, single figure.
- **Apps**: "N apps" icon grid with per-app process-count badges; system processes grouped under "macOS".
- Sampling uses `libproc` (process list, per-process memory footprint, CPU-time deltas), grouped by walking each process's parent chain to the owning app. The 2 s sampler runs only while the window is open. Root-owned processes are counted but can't be measured without privileges.

---

## Using the app

- **Dynamic Island** (Settings → Dynamic Island, off by default): a notch-hugging black pill at the top-center of the screen (flush with the notch on notched Macs, tucked under the menu bar otherwise). Collapsed it shows live status (wind icon, swept dot, Keep Awake countdown); hovering expands it into the island's **own controls hub** — a hero Sweep card (state + Sweep/Restore button), a live CPU/memory mini-card, and a row of quick-action tiles (Desktop, Apps, Keep awake, Clipboard bezel, Monitor). The hub also has a **"Now" live-activity section** (Keep Awake countdown with Stop, app auto-restore countdown with Cancel, desktop-hidden with Restore) and a **⋯ menu** (Island Settings, Open Monitor, Quit Sweep); the collapsed pill shows the same countdowns live. Fully customizable on its settings page: enable toggle, **hide the menu bar icon** (island-only mode), size (Compact / Spacious / **Custom** with Width + Maximum height sliders), show outline, and per-tile Content toggles; changes apply live. Tiles for disabled features stay hidden. The island is a non-activating panel on every Space and drives the System Glance sampler like the popover does.

- **Left-click** the menu bar icon → the panel: Sweep All button, an **icon tab strip** (One Switch-style, selected icon highlighted, selection remembered; Desktop Sweep + App Sweep share one "Sweep" tab, every other feature gets its own; hidden when only one section exists), the selected section's card(s) below it, footer (Open Monitor / Settings / Quit). The card header shows live status: an accent dot while something is running plus a short readout (swept state, Keep Awake countdown, clipping count, CPU %).
- **Right-click** → Open Monitor…, Manage Features…, Settings…, Quit.
- **Settings** (Vorssaint-style): sidebar with search — General (launch at login, global shortcut), Features (overview with toggles + per-feature Options pages), About.
- **Global shortcut**: record it under General; one press sweeps, a second restores. Carbon hotkey — works system-wide, no permissions.
- First launch shows a 3-screen onboarding (what it is → enable your first feature → set the shortcut).

## Permissions

| Permission | Needed by | Why |
|---|---|---|
| **Accessibility** | App Sweep (optional) | Take full-screen/split-view windows out of full screen so they can be hidden; `AXHidden` fallback for stubborn apps. Without it, normal windows still sweep fine. |
| **Accessibility** | Clipboard History (optional) | Only for "Paste immediately after picking" (simulated ⌘V). Without it, picking a clipping just copies it. |

Permissions are requested lazily (explainer sheet first, FR-7). A missing permission shows a warning in Features — never a silent failure.

**If macOS keeps re-asking for Accessibility:** the app must be signed with a *stable* identity. Ad-hoc builds get a new signature each build, so TCC treats each build as a new app. The project is configured to sign with the local Apple Development certificate; if grants ever go stale, run `tccutil reset Accessibility com.hassan.Sweep` and grant once more.

## Architecture

Every feature implements `FeatureModule` (`Sweep/Core/FeatureModule.swift`):

```swift
protocol FeatureModule: AnyObject {
    var id: String { get }
    var name: String { get }
    var summary: String { get }
    var requiredPermissions: [PermissionKind] { get }
    var isEnabled: Bool { get set }      // persisted; false by default
    func activate()                      // start doing work
    func deactivate()                    // stop ALL work, release resources
    func makePanelCard() -> AnyView
    func makeSettingsView() -> AnyView?  // feature Options page
    func appWillTerminate()              // quit ≠ disable: swept state stays saved
}
```

A central `FeatureRegistry` owns all modules in a fixed order (also the panel card order). A disabled module consumes zero resources. `SweepCoordinator` runs Sweep All across the enabled sweep modules and drives the menu bar icon state.

### Source map

```
Sweep/
├── main.swift                    AppKit lifecycle entry
├── AppDelegate.swift             Status item, popover panel, windows, recovery alert
├── Core/
│   ├── FeatureModule.swift       Protocol + PermissionKind (+ grant checks)
│   ├── FeatureRegistry.swift     Module registry, persisted toggles
│   ├── HotkeyManager.swift       Carbon global hotkey + Shortcut model
│   └── LaunchAtLogin.swift       SMAppService wrapper
├── Features/
│   ├── SweepCoordinator.swift    Sweep All + swept-state hub
│   ├── DesktopSweep/             Finder CreateDesktop toggle + relaunch
│   ├── AppSweep/                 Hide/Quit modes, snapshot, exclusions, AX helpers
│   ├── Clipboard/                Flycut-style history (text + images), bezel, paste simulation
│   ├── KeepAwake/                IOPM assertion, durations, battery cut-off
│   └── SystemGlance/             Stats sampler, glance tiles, ProcessMonitor
└── Views/
    ├── PanelView.swift           Menu bar panel (Sweep All, cards, footer)
    ├── SettingsView.swift        Settings window (sidebar, cards, feature pages)
    ├── MonitorView.swift         Monitor window (tabs, app grid, usage lists)
    ├── OnboardingView.swift      First-launch flow
    ├── FeatureCard.swift         Panel card chrome
    ├── ShortcutRecorderView.swift
    └── PermissionExplainerSheet.swift
```

### Persistence

- `UserDefaults`: feature toggles (`feature.<id>.enabled`), per-feature options, swept-state flags, shortcut, onboarding flag.
- JSON on disk: app-session snapshot and clipboard history in `~/Library/Application Support/Sweep/`.

## Building & releasing

```sh
# Debug build
xcodebuild -project Sweep.xcodeproj -scheme Sweep -configuration Debug build

# Distributable dmg (dist/Sweep.dmg)
scripts/make-dmg.sh

# Developer ID signed + notarized dmg
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="your-notarytool-profile" \
scripts/make-dmg.sh
```

The app icon is generated with `swift scripts/generate-icon.swift Sweep/Assets.xcassets/AppIcon.appiconset`.

## Non-functional guarantees

- Idle footprint with all features off: no timers, no observers, nothing loaded.
- No data loss is possible from sweeping: hide-only by default; Quit mode uses polite quits so unsaved work always gets a save dialog.
- No network access of any kind.
- All user-facing strings go through the localization table (English only in v1).
