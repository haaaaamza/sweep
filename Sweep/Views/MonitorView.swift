import SwiftUI
import AppKit

// MARK: - Tabs

enum MonitorTab: String, CaseIterable, Identifiable {
    case overview, cpu, memory, apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return String(localized: "Overview")
        case .cpu: return String(localized: "CPU")
        case .memory: return String(localized: "Memory")
        case .apps: return String(localized: "Apps")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .apps: return "app.badge"
        }
    }
}

// MARK: - Root view

struct MonitorView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var tab: MonitorTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .overview: OverviewTab(monitor: monitor)
                    case .cpu: UsageListTab(monitor: monitor, kind: .cpu)
                    case .memory: UsageListTab(monitor: monitor, kind: .memory)
                    case .apps: AppsGridTab(monitor: monitor)
                    }
                }
                .frame(maxWidth: 760)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
    }

    /// Vitals-style pill tab strip.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(MonitorTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Label(item.title, systemImage: item.icon)
                        .font(.callout.weight(tab == item ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(tab == item ? Color.accentColor.opacity(0.18) : .clear)
                        )
                        .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    @ObservedObject var monitor: ProcessMonitor

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stats = monitor.totals {
                LazyVGrid(columns: columns, spacing: 10) {
                    GlanceTile(
                        icon: "cpu", title: String(localized: "CPU"),
                        value: stats.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                        fraction: stats.cpuPercent.map { $0 / 100 }, tint: .blue
                    )
                    GlanceTile(
                        icon: "memorychip", title: String(localized: "Memory"),
                        value: stats.memoryUsedBytes.map { Format.bytes(Int64($0)) } ?? "—",
                        detail: "of \(Format.bytes(Int64(stats.memoryTotalBytes)))",
                        fraction: stats.memoryUsedBytes.map { Double($0) / Double(max(stats.memoryTotalBytes, 1)) },
                        tint: .purple
                    )
                    GlanceTile(
                        icon: "internaldrive", title: String(localized: "Disk free"),
                        value: stats.diskFreeBytes.map(Format.bytes) ?? "—",
                        detail: stats.diskTotalBytes.map { "of \(Format.bytes($0))" },
                        fraction: diskFraction(stats), tint: .orange
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Busiest right now").font(.headline)
                SettingsCard {
                    let busiest = monitor.groups.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)
                    if busiest.isEmpty {
                        Text("Measuring…")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(20)
                    }
                    ForEach(Array(busiest.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider().padding(.leading, 46) }
                        AppUsageRow(group: group, kind: .cpu, maxValue: max(busiest.first?.cpuPercent ?? 1, 1))
                    }
                }
            }
        }
    }

    private func diskFraction(_ stats: SystemStats) -> Double? {
        guard let free = stats.diskFreeBytes, let total = stats.diskTotalBytes, total > 0 else { return nil }
        return 1 - Double(free) / Double(total)
    }
}

// MARK: - CPU / Memory lists ("processes grouped by app")

private struct UsageListTab: View {
    enum Kind { case cpu, memory }

    @ObservedObject var monitor: ProcessMonitor
    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind == .cpu ? String(localized: "Processor, by app")
                                  : String(localized: "Memory, by app"))
                    .font(.headline)
                Spacer()
                Text("\(monitor.groups.count) apps · helpers included")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard {
                let sorted = sortedGroups.prefix(25)
                if sorted.isEmpty {
                    Text("Measuring…")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(20)
                }
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider().padding(.leading, 46) }
                    AppUsageRow(group: group,
                                kind: kind == .cpu ? .cpu : .memory,
                                maxValue: maxValue)
                }
            }
            Text("Every app gets one row — its helper processes are folded in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sortedGroups: [AppUsageGroup] {
        switch kind {
        case .cpu: return monitor.groups.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return monitor.groups.sorted { $0.memoryBytes > $1.memoryBytes }
        }
    }

    private var maxValue: Double {
        switch kind {
        case .cpu: return max(sortedGroups.first?.cpuPercent ?? 1, 1)
        case .memory: return Double(max(sortedGroups.first?.memoryBytes ?? 1, 1))
        }
    }
}

/// One app row: icon, name + process count, usage bar, figure.
private struct AppUsageRow: View {
    enum Kind { case cpu, memory }

    let group: AppUsageGroup
    let kind: Kind
    let maxValue: Double

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(group: group, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                Text("\(group.processCount) process\(group.processCount == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Capsule()
                .fill(kind == .cpu ? Color.blue : Color.purple)
                .frame(width: max(3, 90 * CGFloat(min(value / maxValue, 1))), height: 4)
                .frame(width: 90, alignment: .leading)
                .background(Capsule().fill(Color.secondary.opacity(0.15)).frame(width: 90, height: 4))

            Text(figure)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var value: Double {
        kind == .cpu ? group.cpuPercent : Double(group.memoryBytes)
    }

    private var figure: String {
        switch kind {
        case .cpu: return String(format: "%.1f%%", group.cpuPercent)
        case .memory: return Format.bytes(Int64(group.memoryBytes))
        }
    }
}

// MARK: - Apps grid ("60 apps")

private struct AppsGridTab: View {
    @ObservedObject var monitor: ProcessMonitor

    private let columns = [GridItem(.adaptive(minimum: 86), spacing: 18)]

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                (Text("\(monitor.groups.count) ").foregroundStyle(.primary)
                 + Text("apps").foregroundStyle(Color.accentColor))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("What Sweep sees right now — every helper counted with its app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(monitor.groups) { group in
                    VStack(spacing: 6) {
                        AppIconView(group: group, size: 52, badge: group.processCount)
                        Text(group.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }
}

/// App icon with an optional process-count badge (bottom-right, Vitals-style).
private struct AppIconView: View {
    let group: AppUsageGroup
    var size: CGFloat
    var badge: Int? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let icon = group.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "apple.logo")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: size * 0.22))
            }
            if let badge {
                Text("\(badge)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .foregroundStyle(.white)
                    .offset(x: 4, y: 2)
            }
        }
    }
}

// MARK: - Shared formatting

private enum Format {
    static func bytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Window controller

final class MonitorWindowController: NSWindowController, NSWindowDelegate {
    private let monitor = ProcessMonitor()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Sweep Monitor")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        self.init(window: window)
        window.contentViewController = NSHostingController(rootView: MonitorView(monitor: monitor))
        window.delegate = self
        window.center()
    }

    func show() {
        monitor.start()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // The sampler must cost nothing while the window is closed.
        monitor.stop()
    }
}
