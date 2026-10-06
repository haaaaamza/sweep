import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted with `userInfo["text"]` (String, may be empty) to update the
    /// optional readout next to the menu bar icon (FR-6.2).
    static let sweepMenuBarReadoutChanged = Notification.Name("sweepMenuBarReadoutChanged")
}

/// FR-6: a small live readout of CPU / memory / disk.
/// The panel refresh timer runs ONLY while the panel is open (FR-6.1);
/// the optional menu bar readout runs its own timer while enabled.
final class SystemGlanceModule: ObservableObject, FeatureModule {
    static let shared = SystemGlanceModule()

    let id = "system-glance"
    let name = String(localized: "System Glance")
    let summary = String(localized: "Live CPU, memory and disk readout — no history, no alerts.")
    let requiredPermissions: [PermissionKind] = []

    @Published private(set) var stats: SystemStats?
    @Published var showMenuBarReadout: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarReadout, forKey: "systemGlance.menuBarReadout")
            guard isActive else { return }
            showMenuBarReadout ? startReadoutTimer() : stopReadoutTimer()
        }
    }

    private var isActive = false
    private var isPanelOpen = false
    private let sampler = SystemStatsSampler()
    private var panelTimer: Timer?
    private var readoutTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        showMenuBarReadout = UserDefaults.standard.bool(forKey: "systemGlance.menuBarReadout")
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .sweepPanelDidOpen, object: nil, queue: .main) { [weak self] _ in
            self?.panelOpened()
        })
        observers.append(center.addObserver(forName: .sweepPanelDidClose, object: nil, queue: .main) { [weak self] _ in
            self?.panelClosed()
        })
        if showMenuBarReadout {
            startReadoutTimer()
        }
    }

    func deactivate() {
        isActive = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        panelClosed()
        stopReadoutTimer()
    }

    // MARK: - Panel refresh (only while the panel is open)

    private func panelOpened() {
        guard panelTimer == nil else { return }
        isPanelOpen = true
        sampler.reset()
        // The open notification fires while the popover's SwiftUI view is
        // being set up — defer the first publish out of that update pass.
        DispatchQueue.main.async { [weak self] in
            self?.refreshPanelStats()
        }
        panelTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshPanelStats()
        }
    }

    private func panelClosed() {
        isPanelOpen = false
        panelTimer?.invalidate()
        panelTimer = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPanelOpen else { return }
            self.stats = nil
        }
    }

    private func refreshPanelStats() {
        stats = sampler.sample()
    }

    // MARK: - Menu bar readout (FR-6.2)

    private let readoutSampler = SystemStatsSampler()

    private func startReadoutTimer() {
        guard readoutTimer == nil else { return }
        readoutSampler.reset()
        readoutTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshReadout()
        }
        refreshReadout()
    }

    private func stopReadoutTimer() {
        readoutTimer?.invalidate()
        readoutTimer = nil
        postReadout("")
    }

    private func refreshReadout() {
        let stats = readoutSampler.sample()
        if let cpu = stats.cpuPercent {
            postReadout(String(format: "CPU %.0f%%", cpu))
        }
    }

    private func postReadout(_ text: String) {
        NotificationCenter.default.post(name: .sweepMenuBarReadoutChanged, object: nil,
                                        userInfo: ["text": text])
    }

    // MARK: - UI

    func makePanelCard() -> AnyView {
        AnyView(SystemGlanceCard(module: self))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(SystemGlanceSettingsView(module: self))
    }
}

// MARK: - Panel card (Vitals-style tiles)

struct GlanceTile: View {
    let icon: String
    let title: String
    let value: String
    var detail: String? = nil
    var fraction: Double? = nil
    var tint: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    if let fraction {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, proxy.size.width * min(max(fraction, 0), 1)))
                    }
                }
            }
            .frame(height: 4)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SystemGlanceCard: View {
    @ObservedObject var module: SystemGlanceModule

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        FeatureCard(id: module.id, title: module.name, systemImage: "gauge.with.needle",
                    detail: statusDetail) {
            if let stats = module.stats {
                LazyVGrid(columns: columns, spacing: 8) {
                    GlanceTile(
                        icon: "cpu", title: String(localized: "CPU"),
                        value: stats.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                        fraction: stats.cpuPercent.map { $0 / 100 },
                        tint: .blue
                    )
                    GlanceTile(
                        icon: "memorychip", title: String(localized: "Memory"),
                        value: stats.memoryUsedBytes.map { Self.formatBytes(Int64($0)) } ?? "—",
                        detail: "of \(Self.formatBytes(Int64(stats.memoryTotalBytes)))",
                        fraction: stats.memoryUsedBytes.map {
                            Double($0) / Double(max(stats.memoryTotalBytes, 1))
                        },
                        tint: .purple
                    )
                    GlanceTile(
                        icon: "internaldrive", title: String(localized: "Disk free"),
                        value: stats.diskFreeBytes.map(Self.formatBytes) ?? "—",
                        detail: stats.diskTotalBytes.map { "of \(Self.formatBytes($0))" },
                        fraction: usedDiskFraction(stats),
                        tint: .orange
                    )
                }
            } else {
                Text("Measuring…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            }
        }
    }

    /// Shown in the card header: a one-glance CPU readout.
    private var statusDetail: String? {
        guard let cpu = module.stats?.cpuPercent else { return nil }
        return String(format: String(localized: "CPU %.0f%%"), cpu)
    }

    private func usedDiskFraction(_ stats: SystemStats) -> Double? {
        guard let free = stats.diskFreeBytes, let total = stats.diskTotalBytes, total > 0 else { return nil }
        return 1 - Double(free) / Double(total)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Feature settings (card style)

struct SystemGlanceSettingsView: View {
    @ObservedObject var module: SystemGlanceModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu bar").font(.headline)
            SettingsCard {
                SettingsRow(icon: "menubar.rectangle",
                            tint: .green,
                            title: String(localized: "Show CPU % next to the menu bar icon"),
                            caption: String(localized: "Updates every 2 seconds while enabled. Off by default.")) {
                    Toggle("", isOn: $module.showMenuBarReadout)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                CardDivider()
                SettingsRow(icon: "bolt.badge.clock",
                            tint: .gray,
                            title: String(localized: "Zero cost when closed"),
                            caption: String(localized: "The panel readout refreshes only while the panel is open. No history, no alerts."))
            }
        }
    }
}
