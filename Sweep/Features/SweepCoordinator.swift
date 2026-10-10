import Foundation
import Combine

/// FR-4: Sweep All — one action that runs every enabled sweep feature
/// (desktop files + apps), and one more that restores everything.
/// Also the single source of truth for the "swept" state shown by the
/// menu bar icon (FR-4.2).
final class SweepCoordinator: ObservableObject {
    static let shared = SweepCoordinator()

    @Published private(set) var isSwept = false

    /// AppDelegate hooks this to swap the menu bar icon.
    var onStateChange: ((Bool) -> Void)?

    private var registry: FeatureRegistry { .shared }
    /// Skip the first sync so relaunching while swept doesn’t flash a pulse.
    private var hasBootstrapped = false

    /// True when at least one sweep feature is enabled, i.e. Sweep All can do something.
    var hasAnySweepFeatureEnabled: Bool {
        registry.isEnabled(DesktopSweepModule.shared.id) || registry.isEnabled(AppSweepModule.shared.id)
    }

    func refreshState() {
        let desktopSwept = registry.isEnabled(DesktopSweepModule.shared.id)
            && DesktopSweepModule.shared.isSwept
        let appsSwept = registry.isEnabled(AppSweepModule.shared.id)
            && AppSweepModule.shared.isSwept
        let newState = desktopSwept || appsSwept
        if newState != isSwept {
            isSwept = newState
            onStateChange?(newState)
            if hasBootstrapped {
                DynamicIslandController.shared.presentPulse(newState ? .swept : .restored)
            }
        }
        hasBootstrapped = true
    }

    func toggleSweepAll() {
        isSwept ? restoreAll() : sweepAll()
    }

    func sweepAll() {
        if registry.isEnabled(DesktopSweepModule.shared.id) {
            DesktopSweepModule.shared.sweep()
        }
        if registry.isEnabled(AppSweepModule.shared.id) {
            AppSweepModule.shared.sweep()
        }
        refreshState()
    }

    func restoreAll() {
        if registry.isEnabled(DesktopSweepModule.shared.id) {
            DesktopSweepModule.shared.restore()
        }
        if registry.isEnabled(AppSweepModule.shared.id) {
            AppSweepModule.shared.restore()
        }
        refreshState()
    }
}
