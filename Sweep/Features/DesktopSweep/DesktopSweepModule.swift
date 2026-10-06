import SwiftUI
import AppKit

/// FR-2: hide/show all desktop icons by toggling Finder's `CreateDesktop`
/// preference and relaunching Finder. Files never move — zero data risk.
final class DesktopSweepModule: ObservableObject, FeatureModule {
    static let shared = DesktopSweepModule()

    let id = "desktop-sweep"
    let name = String(localized: "Desktop Sweep")
    let summary = String(localized: "Hide every icon on the desktop with one click. Files never move.")
    let requiredPermissions: [PermissionKind] = []

    /// FR-2.2: swept state is tracked by the app itself, persisted so it
    /// survives relaunches and crashes (FR-2.3).
    @Published private(set) var isSwept: Bool = UserDefaults.standard.bool(forKey: "desktopSweep.isSwept")

    func activate() {}

    func deactivate() {
        // Never leave the desktop hidden with the feature (and its UI) gone.
        if isSwept { restore() }
    }

    /// Quitting keeps the swept state saved: relaunching the app offers
    /// restore, and the panel still shows the Restore button (FR-2.3).
    func appWillTerminate() {}

    func toggle() {
        isSwept ? restore() : sweep()
    }

    func sweep() {
        guard !isSwept else { return }
        setSweptState(true)
        FinderDesktop.setIconsVisible(false)
    }

    func restore() {
        guard isSwept else { return }
        setSweptState(false)
        FinderDesktop.setIconsVisible(true)
    }

    private func setSweptState(_ swept: Bool) {
        isSwept = swept
        UserDefaults.standard.set(swept, forKey: "desktopSweep.isSwept")
        SweepCoordinator.shared.refreshState()
    }

    func makePanelCard() -> AnyView {
        AnyView(DesktopSweepCard(module: self))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(DesktopSweepSettingsView(module: self))
    }
}

struct DesktopSweepSettingsView: View {
    @ObservedObject var module: DesktopSweepModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Status").font(.headline)
            SettingsCard {
                SettingsRow(icon: module.isSwept ? "eye.slash" : "eye",
                            tint: module.isSwept ? .orange : .blue,
                            title: module.isSwept
                                ? String(localized: "Desktop icons are hidden")
                                : String(localized: "Desktop icons are visible"),
                            caption: String(localized: "Files never move — hiding only changes what Finder draws. Zero data risk.")) {
                    Button(module.isSwept ? String(localized: "Restore Now")
                                          : String(localized: "Hide Now")) {
                        module.toggle()
                    }
                    .controlSize(.small)
                }
                CardDivider()
                SettingsRow(icon: "arrow.counterclockwise",
                            tint: .gray,
                            title: String(localized: "Crash safe"),
                            caption: String(localized: "If Sweep closes while the desktop is hidden, the next launch offers to restore it."))
            }
        }
    }
}

/// Talks to Finder's defaults. Not sandboxed, so this needs no permission:
/// we write the preference directly and send Finder a polite terminate —
/// launchd relaunches it immediately with the new setting.
enum FinderDesktop {
    static func setIconsVisible(_ visible: Bool) {
        CFPreferencesSetValue("CreateDesktop" as CFString,
                              visible ? kCFBooleanTrue : kCFBooleanFalse,
                              "com.apple.finder" as CFString,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        relaunchFinder()
    }

    private static let finderBundleID = "com.apple.finder"
    private static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    private static func relaunchFinder() {
        let finders = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID)
        guard !finders.isEmpty else {
            launchFinder()
            return
        }
        for finder in finders {
            finder.terminate()
        }
        // macOS only auto-relaunches Finder after a force-kill, NOT after a
        // polite terminate — so wait for it to exit, then start it ourselves.
        waitAndLaunchFinder(attempts: 0)
    }

    private static func waitAndLaunchFinder(attempts: Int) {
        let stillRunning = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID)
            .contains { !$0.isTerminated }
        if stillRunning {
            if attempts < 20 { // up to ~3 s of polling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    waitAndLaunchFinder(attempts: attempts + 1)
                }
                return
            }
            // It ignored the polite quit; force it (macOS relaunches it after this).
            NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleID)
                .forEach { $0.forceTerminate() }
            return
        }
        launchFinder()
    }

    private static func launchFinder() {
        NSWorkspace.shared.openApplication(at: finderURL,
                                           configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

struct DesktopSweepCard: View {
    @ObservedObject var module: DesktopSweepModule

    var body: some View {
        FeatureCard(id: module.id, title: module.name, systemImage: "menubar.dock.rectangle",
                    isActive: module.isSwept,
                    detail: module.isSwept ? String(localized: "Hidden") : nil) {
            Button(action: { module.toggle() }) {
                Label(module.isSwept ? String(localized: "Restore Desktop Icons")
                                     : String(localized: "Hide Desktop Icons"),
                      systemImage: module.isSwept ? "eye" : "eye.slash")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(module.isSwept ? .orange : nil)

            if module.isSwept {
                Text("Desktop icons are hidden. Your files are untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
