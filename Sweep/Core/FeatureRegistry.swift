import Foundation
import Combine

/// Central owner of all feature modules (SRS §2.1).
/// Modules are registered once at launch in a fixed order; that order is
/// also the fixed display order of panel cards (FR-1.2).
final class FeatureRegistry: ObservableObject {
    static let shared = FeatureRegistry()

    private(set) var modules: [FeatureModule] = []
    @Published private(set) var enabledIDs: Set<String> = []

    func register(_ module: FeatureModule) {
        modules.append(module)
    }

    /// Activate every module the user had enabled in a previous run (FR-1.5).
    func bootstrap() {
        for module in modules where module.isEnabled {
            enabledIDs.insert(module.id)
            module.activate()
        }
    }

    var enabledModules: [FeatureModule] {
        modules.filter { enabledIDs.contains($0.id) }
    }

    func isEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let module = modules.first(where: { $0.id == id }),
              enabled != isEnabled(id) else { return }
        module.isEnabled = enabled
        if enabled {
            enabledIDs.insert(id)
            module.activate()
        } else {
            enabledIDs.remove(id)
            module.deactivate()
        }
    }

    /// App is quitting: stop running work (timers, assertions) WITHOUT
    /// undoing persisted state — a swept desktop must stay swept (FR-2.3).
    func appWillTerminate() {
        for module in modules where isEnabled(module.id) {
            module.appWillTerminate()
        }
    }
}
