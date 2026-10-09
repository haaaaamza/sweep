import SwiftUI

extension Notification.Name {
    /// Posted with `userInfo["section"]` (SettingsSection rawValue) when a
    /// view wants the settings window opened on a given tab.
    static let sweepOpenSettings = Notification.Name("sweepOpenSettings")
}

/// The popover shown on left-click of the menu bar icon.
/// Shows one card per enabled feature, in registry (fixed) order (FR-1.2).
struct PanelView: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var coordinator = SweepCoordinator.shared

    /// The section whose card is shown; remembered across panel opens.
    @AppStorage("panel.selectedFeature") private var selectedID: String = ""

    /// One tab in the panel's icon strip. Desktop Sweep and App Sweep share
    /// a single "Sweep" section; every other feature gets its own.
    private struct PanelSection: Identifiable {
        let id: String
        let name: String
        let icon: String
        let modules: [FeatureModule]
    }

    var body: some View {
        VStack(spacing: 10) {
            if coordinator.hasAnySweepFeatureEnabled {
                sweepAllButton
            }
            if registry.enabledModules.isEmpty {
                emptyState
            } else {
                if sections.count > 1 {
                    tabStrip
                }
                if let section = selectedSection {
                    ForEach(section.modules, id: \.id) { module in
                        module.makePanelCard()
                    }
                }
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var sections: [PanelSection] {
        var result: [PanelSection] = []
        let sweepIDs = ["desktop-sweep", "app-sweep"]
        let sweepModules = registry.enabledModules.filter { sweepIDs.contains($0.id) }
        for module in registry.enabledModules {
            if sweepIDs.contains(module.id) {
                // Both sweeps live under one section, added where the first sits.
                if result.contains(where: { $0.id == "sweep" }) { continue }
                result.append(PanelSection(id: "sweep",
                                           name: String(localized: "Sweep"),
                                           icon: "wind",
                                           modules: sweepModules))
            } else {
                result.append(PanelSection(id: module.id,
                                           name: module.name,
                                           icon: FeatureUI.icon(for: module.id),
                                           modules: [module]))
            }
        }
        return result
    }

    private var selectedSection: PanelSection? {
        // Old per-feature selections map onto the merged sweep section.
        let wanted = ["desktop-sweep", "app-sweep"].contains(selectedID) ? "sweep" : selectedID
        return sections.first { $0.id == wanted } ?? sections.first
    }

    /// One Switch-style section switcher, selected icon highlighted.
    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(sections) { section in
                tab(for: section)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tab(for section: PanelSection) -> some View {
        let isSelected = section.id == selectedSection?.id
        return Button {
            selectedID = section.id
        } label: {
            Image(systemName: section.icon)
                .font(.system(size: 15, weight: .medium))
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    isSelected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(section.name)
        .accessibilityLabel(section.name)
    }

    /// Footer: open settings, or quit.
    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openSettings(.general)
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help("Quit Sweep")
        }
    }

    private func openSettings(_ section: SettingsSection) {
        NotificationCenter.default.post(name: .sweepOpenSettings, object: nil,
                                        userInfo: ["section": section.rawValue])
    }

    /// FR-4.3: Sweep All is the panel's main button.
    private var sweepAllButton: some View {
        Button(action: { coordinator.toggleSweepAll() }) {
            Label(coordinator.isSwept ? String(localized: "Restore Everything")
                                      : String(localized: "Sweep All"),
                  systemImage: coordinator.isSwept ? "arrow.uturn.backward" : "wind")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(coordinator.isSwept ? .orange : .accentColor)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wind")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Sweep")
                .font(.headline)
            Text("No features enabled yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Enable Features…") {
                openSettings(.features)
            }
        }
        .padding(.vertical, 8)
    }
}
