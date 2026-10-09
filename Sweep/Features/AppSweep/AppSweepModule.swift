import SwiftUI
import AppKit
import ApplicationServices

/// Snapshot of what was running when the user swept (FR-3.4).
/// Saved as JSON so restore works even after the app relaunches.
struct AppSnapshot: Codable {
    var bundleIDs: [String]
    var frontmostBundleID: String?
    var date: Date
    /// Apps that had full-screen / split-view windows we exited before hiding;
    /// restore puts them back into full screen. Optional: older snapshots lack it.
    var fullscreenBundleIDs: [String]?
    /// bundleID → app bundle path, so quit apps can be relaunched on restore.
    var appURLs: [String: String]?
    /// bundleID → display name, for the session summary on the card.
    var appNames: [String: String]?
    /// "hide" or "quit" — how this session was swept.
    var mode: String?
}

/// FR-3: hide all running apps and restore them later. Hide-only in v1 —
/// never quit, never risk unsaved work (NFR-3).
final class AppSweepModule: ObservableObject, FeatureModule {
    static let shared = AppSweepModule()

    let id = "app-sweep"
    let name = String(localized: "App Sweep")
    let summary = String(localized: "Hide every running app in one click, bring them all back with the next.")
    /// Accessibility lets us also hide full-screen / split-view apps by taking
    /// their windows out of full screen first. Without it, hiding still works
    /// for normal windows.
    let requiredPermissions: [PermissionKind] = [.accessibility]

    /// Hide keeps apps running (instant restore); Quit closes them politely
    /// (saves battery — apps with unsaved work get asked to save first).
    enum SweepMode: String, CaseIterable {
        case hide, quit

        var label: String {
            switch self {
            case .hide: return String(localized: "Hide")
            case .quit: return String(localized: "Quit")
            }
        }
    }

    /// Later-style "get back in the flow" auto-restore delays (minutes; 0 = off).
    enum AutoRestore: Int, CaseIterable, Identifiable {
        case off = 0, fifteen = 15, thirty = 30, hour = 60, fiveHours = 300

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .off: return String(localized: "Off")
            case .fifteen: return String(localized: "15 minutes")
            case .thirty: return String(localized: "30 minutes")
            case .hour: return String(localized: "1 hour")
            case .fiveHours: return String(localized: "5 hours")
            }
        }
    }

    @Published private(set) var isSwept: Bool = UserDefaults.standard.bool(forKey: "appSweep.isSwept")
    @Published var excludedBundleIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(excludedBundleIDs), forKey: "appSweep.excluded")
        }
    }
    @Published var mode: SweepMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appSweep.mode") }
    }
    @Published var autoRestore: AutoRestore {
        didSet { UserDefaults.standard.set(autoRestore.rawValue, forKey: "appSweep.autoRestore") }
    }
    /// Seconds until the session is restored automatically (nil = no timer).
    @Published private(set) var autoRestoreRemaining: TimeInterval?
    /// Short session summary ("Safari, Notes, +3 more · 5:12 PM") while swept.
    @Published private(set) var sessionSummary: String?

    private var autoRestoreDeadline: Date?
    private var autoRestoreTimer: Timer?

    private var snapshotURL: URL {
        AppSupport.directory.appendingPathComponent("app-snapshot.json")
    }

    init() {
        let defaults = UserDefaults.standard
        excludedBundleIDs = Set(defaults.stringArray(forKey: "appSweep.excluded") ?? [])
        mode = SweepMode(rawValue: defaults.string(forKey: "appSweep.mode") ?? "") ?? .hide
        autoRestore = AutoRestore(rawValue: defaults.integer(forKey: "appSweep.autoRestore")) ?? .off
        if isSwept {
            sessionSummary = Self.summary(for: loadSnapshot())
        }
    }

    func activate() {
        // Trigger the system Accessibility prompt the first time (FR-7: the
        // explainer sheet has already run by the time we get here).
        if !PermissionKind.accessibility.isGranted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
    }

    func deactivate() {
        // Never leave the user's apps hidden with the feature gone.
        if isSwept { restore() }
    }

    /// Quitting keeps the swept state and snapshot on disk, so the next
    /// launch can still restore the hidden apps (FR-3.4).
    func appWillTerminate() {}

    func toggle() {
        isSwept ? restore() : sweep()
    }

    /// FR-3.1: snapshot all regular apps, then hide them — or, in Quit mode
    /// (Later-style), close them politely so they can be relaunched on restore.
    /// Full-screen / split-view windows leave full screen first because macOS
    /// ignores hide() for them.
    ///
    /// Sweeping while already marked swept still sweeps whatever is visible:
    /// the state goes stale when apps are brought back manually (Dock click,
    /// Cmd-Tab), and a sweep that silently does nothing looks broken. The new
    /// snapshot is merged into the old one so restore still covers everything.
    func sweep() {
        let previous = isSwept ? loadSnapshot() : nil

        let workspace = NSWorkspace.shared
        let frontmost = workspace.runningApplications
            .first { $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier }?
            .bundleIdentifier
        let targets = workspace.runningApplications.filter { app in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,   // Sweep itself: always excluded (FR-3.3)
                  !excludedBundleIDs.contains(bundleID),
                  !app.isHidden
            else { return false }
            return true
        }

        // Exit full screen / split view where we can (needs Accessibility).
        // Only relevant when hiding; quitting closes the windows anyway.
        var fullscreenBundleIDs = previous?.fullscreenBundleIDs ?? []
        if mode == .hide, PermissionKind.accessibility.isGranted {
            for app in targets {
                let fullscreenWindows = AX.fullscreenWindows(pid: app.processIdentifier)
                guard !fullscreenWindows.isEmpty, let bundleID = app.bundleIdentifier else { continue }
                if !fullscreenBundleIDs.contains(bundleID) {
                    fullscreenBundleIDs.append(bundleID)
                }
                fullscreenWindows.forEach { AX.setFullscreen($0, false) }
            }
        }

        var bundleIDs = previous?.bundleIDs ?? []
        var appURLs = previous?.appURLs ?? [:]
        var appNames = previous?.appNames ?? [:]
        for app in targets {
            guard let bundleID = app.bundleIdentifier else { continue }
            if !bundleIDs.contains(bundleID) { bundleIDs.append(bundleID) }
            if let path = app.bundleURL?.path { appURLs[bundleID] = path }
            appNames[bundleID] = app.localizedName ?? bundleID
        }

        let snapshot = AppSnapshot(
            bundleIDs: bundleIDs,
            frontmostBundleID: previous?.frontmostBundleID ?? frontmost,
            date: Date(),
            fullscreenBundleIDs: fullscreenBundleIDs,
            appURLs: appURLs,
            appNames: appNames,
            mode: mode.rawValue
        )
        saveSnapshot(snapshot)
        setSweptState(true)
        sessionSummary = Self.summary(for: snapshot)

        switch mode {
        case .hide:
            // Hiding during the leave-full-screen animation gets ignored, so
            // give it a beat when any window had to exit full screen first.
            let delay: TimeInterval = fullscreenBundleIDs.isEmpty ? 0 : 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.hideApps(targets, attempt: 0)
            }
        case .quit:
            for app in targets {
                // Never quit Finder — hide it instead (Later does the same).
                if app.bundleIdentifier == "com.apple.finder" {
                    app.hide()
                } else {
                    // Polite quit only: an app with unsaved work shows its
                    // save dialog and stays if the user cancels (NFR-3).
                    app.terminate()
                }
            }
        }

        startAutoRestoreIfNeeded()
    }

    // MARK: - Auto-restore ("get back in the flow")

    private func startAutoRestoreIfNeeded() {
        stopAutoRestoreTimer()
        guard autoRestore != .off else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(autoRestore.rawValue * 60))
        autoRestoreDeadline = deadline
        autoRestoreRemaining = deadline.timeIntervalSinceNow
        autoRestoreTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let deadline = self.autoRestoreDeadline else { return }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 {
                self.restore()
            } else {
                self.autoRestoreRemaining = left
            }
        }
    }

    func cancelAutoRestore() {
        stopAutoRestoreTimer()
    }

    private func stopAutoRestoreTimer() {
        autoRestoreTimer?.invalidate()
        autoRestoreTimer = nil
        autoRestoreDeadline = nil
        autoRestoreRemaining = nil
    }

    /// mm:ss countdown for the auto-restore timer.
    static func formatInterval(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func summary(for snapshot: AppSnapshot?) -> String? {
        guard let snapshot, !snapshot.bundleIDs.isEmpty else { return nil }
        let names = snapshot.bundleIDs.compactMap { snapshot.appNames?[$0] }
        guard !names.isEmpty else { return nil }
        var text = names.prefix(3).joined(separator: ", ")
        if names.count > 3 { text += ", +\(names.count - 3) more" }
        let time = snapshot.date.formatted(date: .omitted, time: .shortened)
        return "\(text) · \(time)"
    }

    /// hide() can fail or be silently ignored for some apps (heavy apps like
    /// Xcode, apps mid-deactivation). Verify, retry, then fall back to the
    /// Accessibility API's AXHidden, which lands where hide() does not.
    private static func hideApps(_ apps: [NSRunningApplication], attempt: Int) {
        for app in apps where !app.isHidden && !app.isTerminated {
            app.hide()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let stillVisible = apps.filter { !$0.isHidden && !$0.isTerminated }
            guard !stillVisible.isEmpty else { return }
            if attempt < 2 {
                hideApps(stillVisible, attempt: attempt + 1)
            } else if PermissionKind.accessibility.isGranted {
                for app in stillVisible {
                    AX.setAppHidden(app.processIdentifier, true)
                }
            }
        }
    }

    /// FR-3.2: bring the session back. Running apps are unhidden; apps that
    /// were quit (Quit mode) are relaunched from their saved bundle path,
    /// Later-style. Apps launched after the sweep are left alone. The
    /// previously frontmost app is re-activated.
    func restore() {
        guard isSwept else { return }
        stopAutoRestoreTimer()
        let snapshot = loadSnapshot()
        setSweptState(false)
        sessionSummary = nil

        guard let snapshot else { return }
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))

        for bundleID in snapshot.bundleIDs {
            if runningIDs.contains(bundleID) {
                for app in running where app.bundleIdentifier == bundleID {
                    app.unhide()
                }
            } else if let path = snapshot.appURLs?[bundleID] {
                // The app was quit — launch it again.
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: path),
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            }
        }

        // Refocus the previously frontmost app once unhide/relaunch has landed.
        if let frontID = snapshot.frontmostBundleID {
            let delay: TimeInterval = runningIDs.contains(frontID) ? 0.2 : 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSWorkspace.shared.runningApplications
                    .first { $0.bundleIdentifier == frontID }?
                    .activate()
            }
        }

        // Put previously full-screen windows back into full screen.
        if let fullscreenIDs = snapshot.fullscreenBundleIDs, !fullscreenIDs.isEmpty,
           PermissionKind.accessibility.isGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                for bundleID in fullscreenIDs {
                    for app in NSWorkspace.shared.runningApplications
                    where app.bundleIdentifier == bundleID {
                        if let window = AX.windows(pid: app.processIdentifier).first {
                            AX.setFullscreen(window, true)
                        }
                    }
                }
            }
        }
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private func setSweptState(_ swept: Bool) {
        isSwept = swept
        UserDefaults.standard.set(swept, forKey: "appSweep.isSwept")
        SweepCoordinator.shared.refreshState()
    }

    // MARK: - Snapshot persistence (FR-3.4)

    private func saveSnapshot(_ snapshot: AppSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func loadSnapshot() -> AppSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(AppSnapshot.self, from: data)
    }

    // MARK: - UI

    func makePanelCard() -> AnyView {
        AnyView(AppSweepCard(module: self))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(AppSweepSettingsView(module: self))
    }
}

/// Minimal Accessibility helpers for full-screen window handling.
enum AX {
    static func windows(pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        // Don't let one unresponsive app stall the sweep (default is ~6 s),
        // but give heavy apps (Xcode…) enough time to answer.
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// The application-level AXHidden attribute: same semantics as hide(),
    /// but delivered through the Accessibility connection.
    static func setAppHidden(_ pid: pid_t, _ hidden: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString,
                                     hidden ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Full-screen AND split-view (tiled) windows both report AXFullScreen.
    static func fullscreenWindows(pid: pid_t) -> [AXUIElement] {
        windows(pid: pid).filter { window in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else {
                return false
            }
            return (value as? Bool) == true
        }
    }

    static func setFullscreen(_ window: AXUIElement, _ fullscreen: Bool) {
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString,
                                     fullscreen ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

/// JSON snapshots live in ~/Library/Application Support/Sweep/ (SRS §2).
enum AppSupport {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Panel card

struct AppSweepCard: View {
    @ObservedObject var module: AppSweepModule

    var body: some View {
        FeatureCard(id: module.id, title: module.name, systemImage: "macwindow.on.rectangle",
                    isActive: module.isSwept,
                    detail: module.isSwept ? String(localized: "Swept") : nil) {
            Button(action: { module.toggle() }) {
                Label(buttonTitle, systemImage: module.isSwept ? "macwindow" : "rectangle.stack.badge.minus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(module.isSwept ? .orange : nil)

            if module.isSwept {
                if let summary = module.sessionSummary {
                    // Later-style saved-session metadata.
                    Label(summary, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let remaining = module.autoRestoreRemaining {
                    HStack {
                        Text("Reopening in \(AppSweepModule.formatInterval(remaining))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { module.cancelAutoRestore() }
                            .controlSize(.mini)
                            .buttonStyle(.borderless)
                    }
                } else {
                    Text(module.mode == .quit
                         ? String(localized: "Apps were asked to quit — restore reopens them.")
                         : String(localized: "Apps are hidden, not quit — nothing is lost."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var buttonTitle: String {
        if module.isSwept {
            return module.mode == .quit ? String(localized: "Reopen Apps")
                                        : String(localized: "Bring Apps Back")
        }
        return module.mode == .quit ? String(localized: "Close All Apps")
                                    : String(localized: "Hide All Apps")
    }
}

// MARK: - Exclusion list + permission state (FR-3.3 / FR-7.2)

struct AppSweepSettingsView: View {
    @ObservedObject var module: AppSweepModule
    @State private var runningApps: [NSRunningApplication] = []
    @State private var accessibilityGranted = PermissionKind.accessibility.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sweep mode").font(.headline)
                SettingsCard {
                    SettingsRow(icon: module.mode == .quit ? "xmark.rectangle" : "eye.slash",
                                tint: module.mode == .quit ? .red : .indigo,
                                title: String(localized: "What happens to swept apps"),
                                caption: module.mode == .quit
                                    ? String(localized: "Apps are asked to quit politely — unsaved work always gets a save dialog, and Finder is only hidden. Restore reopens everything. Saves battery.")
                                    : String(localized: "Apps are hidden, never quit. Restore is instant and nothing can be lost.")) {
                        Picker("", selection: $module.mode) {
                            ForEach(AppSweepModule.SweepMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    CardDivider()
                    SettingsRow(icon: "clock.arrow.circlepath",
                                tint: .teal,
                                title: String(localized: "Reopen automatically"),
                                caption: String(localized: "After a sweep, bring the whole session back by itself — get back in the flow.")) {
                        Picker("", selection: $module.autoRestore) {
                            ForEach(AppSweepModule.AutoRestore.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions").font(.headline)
                SettingsCard {
                    SettingsRow(icon: accessibilityGranted ? "checkmark.shield" : "lock.shield",
                                tint: accessibilityGranted ? .green : .orange,
                                title: String(localized: "Accessibility"),
                                caption: accessibilityGranted
                                    ? String(localized: "Granted — full-screen and split-view apps are hidden too.")
                                    : String(localized: "Not granted — full-screen and split-view windows can't be hidden. Normal windows still work.")) {
                        if !accessibilityGranted {
                            Button(String(localized: "Open System Settings…")) {
                                NSWorkspace.shared.open(PermissionKind.accessibility.settingsDeepLink)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Never hide these apps").font(.headline)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Turn an app ON to protect it — Sweep will never hide it. Everything OFF here gets swept. Sweep itself is always protected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 0) {
                            ForEach(Array(runningApps.enumerated()), id: \.element.processIdentifier) { index, app in
                                if let bundleID = app.bundleIdentifier {
                                    if index > 0 { Divider() }
                                    HStack(spacing: 8) {
                                        Image(nsImage: app.icon ?? NSImage())
                                            .resizable()
                                            .frame(width: 20, height: 20)
                                        Text(app.localizedName ?? bundleID)
                                        Spacer()
                                        if module.excludedBundleIDs.contains(bundleID) {
                                            Text("Never hidden")
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.orange)
                                        }
                                        Toggle("", isOn: exclusionBinding(for: bundleID))
                                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }

                        if !staleExclusions.isEmpty {
                            Text("Also excluded (not currently running): \(staleExclusions.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onAppear {
            refreshRunningApps()
            accessibilityGranted = PermissionKind.accessibility.isGranted
        }
    }

    private var staleExclusions: [String] {
        let runningIDs = Set(runningApps.compactMap(\.bundleIdentifier))
        return module.excludedBundleIDs.subtracting(runningIDs).sorted()
    }

    private func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func exclusionBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { module.excludedBundleIDs.contains(bundleID) },
            set: { excluded in
                if excluded {
                    module.excludedBundleIDs.insert(bundleID)
                } else {
                    module.excludedBundleIDs.remove(bundleID)
                }
            }
        )
    }
}
