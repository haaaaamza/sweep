import SwiftUI
import ApplicationServices

/// Permissions a feature may need. Requested lazily (FR-7): the explainer
/// sheet is shown when the user enables a feature that needs one.
enum PermissionKind: String, CaseIterable, Codable {
    case appManagement
    case automation
    case accessibility

    var displayName: String {
        switch self {
        case .appManagement: return NSLocalizedString("App Management", comment: "")
        case .automation: return NSLocalizedString("Automation", comment: "")
        case .accessibility: return NSLocalizedString("Accessibility", comment: "")
        }
    }

    var explanation: String {
        switch self {
        case .appManagement:
            return NSLocalizedString("Sweep needs App Management access to manage other apps on your behalf.", comment: "")
        case .automation:
            return NSLocalizedString("Sweep needs Automation access to ask Finder to refresh the desktop.", comment: "")
        case .accessibility:
            return NSLocalizedString("Sweep needs Accessibility access to take full-screen and split-view windows out of full screen, so those apps can be hidden too. Without it, only normal windows are hidden.", comment: "")
        }
    }

    /// Deep link to the matching System Settings pane.
    var settingsDeepLink: URL {
        switch self {
        case .appManagement:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
        case .automation:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    /// Whether the permission is currently granted (FR-7.2 warning state).
    var isGranted: Bool {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .appManagement, .automation: return true // not used by v1 features
        }
    }
}

/// Every Sweep feature is a self-contained module (SRS §2.1).
/// When `isEnabled == false` a module must consume zero resources:
/// no timers, no observers, nothing running.
protocol FeatureModule: AnyObject {
    var id: String { get }
    var name: String { get }
    var summary: String { get }          // one line shown in settings
    var requiredPermissions: [PermissionKind] { get }
    var isEnabled: Bool { get set }      // persisted; false by default
    func activate()                      // start doing work
    func deactivate()                    // stop ALL work, release resources

    /// The card shown in the menu bar panel while the module is enabled.
    func makePanelCard() -> AnyView
    /// Optional per-feature settings UI (nil = none).
    func makeSettingsView() -> AnyView?
    /// Called when the app is quitting. Unlike `deactivate()` (the user turned
    /// the feature off), this must NOT undo persisted state: a swept desktop
    /// stays swept and is offered for restore on next launch (FR-2.3).
    func appWillTerminate()
}

extension FeatureModule {
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "feature.\(id).enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "feature.\(id).enabled") }
    }

    func makeSettingsView() -> AnyView? { nil }

    func appWillTerminate() { deactivate() }
}
