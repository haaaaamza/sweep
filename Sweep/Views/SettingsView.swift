import SwiftUI
import AppKit

// MARK: - Navigation model

/// External anchors used by the panel / status-bar menu to open a tab.
enum SettingsSection: String {
    case general, features, island, about
}

enum SettingsPage: Hashable {
    case general
    case features
    case island
    case about
    case feature(String)        // module id
}

/// Shared so the settings window can be opened on a specific page.
final class SettingsState: ObservableObject {
    static let shared = SettingsState()
    @Published var selection: SettingsPage? = .general

    func open(_ section: SettingsSection) {
        switch section {
        case .general: selection = .general
        case .features: selection = .features
        case .island: selection = .island
        case .about: selection = .about
        }
    }
}

// MARK: - Shared building blocks (Vorssaint-style cards)

/// A rounded card that stacks rows with inset dividers.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One settings row: tinted icon box, title + caption, trailing control.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    var tint: Color = .blue
    let title: String
    var caption: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(icon: String, tint: Color = .blue, title: String, caption: String? = nil) {
        self.init(icon: icon, tint: tint, title: title, caption: caption) { EmptyView() }
    }
}

struct CardDivider: View {
    var body: some View {
        Divider().padding(.leading, 54)
    }
}

/// Page scaffold: title, subtitle, content column.
struct SettingsPageScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.bold))
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Capsule chip picker for discrete options.
struct ChipPicker<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.caption.weight(selection == option.value ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selection == option.value
                                           ? Color.accentColor.opacity(0.22)
                                           : Color.secondary.opacity(0.12))
                        )
                        .overlay(
                            Capsule().strokeBorder(selection == option.value
                                                   ? Color.accentColor
                                                   : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(selection == option.value ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Feature metadata for the UI

enum FeatureUI {
    static func icon(for id: String) -> String {
        switch id {
        case "desktop-sweep": return "menubar.dock.rectangle"
        case "app-sweep": return "macwindow.on.rectangle"
        case "clipboard": return "doc.on.clipboard"
        default: return "puzzlepiece"
        }
    }

    static func tint(for id: String) -> Color {
        switch id {
        case "desktop-sweep": return .blue
        case "app-sweep": return .indigo
        case "clipboard": return .teal
        default: return .gray
        }
    }
}

// MARK: - Feature enable toggle (with FR-7 permission explainer)

private struct PermissionPrompt: Identifiable {
    let id: String
    let kinds: [PermissionKind]
}

struct FeatureToggleControl: View {
    @ObservedObject var registry: FeatureRegistry
    let module: FeatureModule
    @State private var prompt: PermissionPrompt?

    var body: some View {
        Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .sheet(item: $prompt) { prompt in
                PermissionExplainerSheet(
                    featureName: module.name,
                    permissions: prompt.kinds,
                    onContinue: {
                        registry.setEnabled(module.id, true)
                        self.prompt = nil
                    },
                    onCancel: { self.prompt = nil }
                )
            }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { registry.isEnabled(module.id) },
            set: { enabled in
                if enabled {
                    let pending = PermissionExplainers.pendingKinds(for: module)
                    if !pending.isEmpty {
                        prompt = PermissionPrompt(id: module.id, kinds: pending)
                        return
                    }
                }
                registry.setEnabled(module.id, enabled)
            }
        )
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject private var state = SettingsState.shared
    @State private var query = ""

    private struct SidebarItem {
        let page: SettingsPage
        let title: String
        let icon: String
    }

    private var essentials: [SidebarItem] {
        [
            SidebarItem(page: .general, title: String(localized: "General"), icon: "gearshape"),
            SidebarItem(page: .features, title: String(localized: "Features"), icon: "square.grid.2x2"),
            SidebarItem(page: .island, title: String(localized: "Dynamic Island"), icon: "oval.fill"),
        ]
    }

    private var featureItems: [SidebarItem] {
        registry.modules.map {
            SidebarItem(page: .feature($0.id), title: $0.name, icon: FeatureUI.icon(for: $0.id))
        }
    }

    private var appItems: [SidebarItem] {
        [SidebarItem(page: .about, title: String(localized: "About"), icon: "info.circle")]
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section(String(localized: "Essentials")) {
                    ForEach(filtered(essentials), id: \.page) { item in
                        Label(item.title, systemImage: item.icon).tag(item.page)
                    }
                }
                Section(String(localized: "Features")) {
                    ForEach(filtered(featureItems), id: \.page) { item in
                        Label(item.title, systemImage: item.icon).tag(item.page)
                    }
                }
                Section(String(localized: "App")) {
                    ForEach(filtered(appItems), id: \.page) { item in
                        Label(item.title, systemImage: item.icon).tag(item.page)
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Search settings"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            detailView
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    private func filtered(_ items: [SidebarItem]) -> [SidebarItem] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var detailView: some View {
        switch state.selection ?? .general {
        case .general:
            GeneralSettingsPage()
        case .features:
            FeaturesOverviewPage(registry: registry)
        case .island:
            IslandSettingsPage()
        case .about:
            AboutPage()
        case .feature(let id):
            if let module = registry.modules.first(where: { $0.id == id }) {
                FeatureDetailPage(registry: registry, module: module)
            } else {
                FeaturesOverviewPage(registry: registry)
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        SettingsPageScaffold(title: String(localized: "General")) {
            SettingsCard {
                SettingsRow(icon: "laptopcomputer",
                            title: String(localized: "Launch at login"),
                            caption: String(localized: "Opens by itself every time you turn on your Mac.")) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                try LaunchAtLogin.set(newValue)
                                launchAtLoginError = nil
                            } catch {
                                launchAtLoginError = error.localizedDescription
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }
                        }
                }
                if let launchAtLoginError {
                    CardDivider()
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Global shortcut").font(.headline)
                SettingsCard {
                    SettingsRow(icon: "keyboard",
                                title: String(localized: "Sweep All shortcut"),
                                caption: String(localized: "One press sweeps, a second press restores. Works in any app, no extra permissions.")) {
                        ShortcutRecorderView()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(.headline)
                SettingsCard {
                    SettingsRow(icon: "circle.lefthalf.filled",
                                title: String(localized: "Follows the system"),
                                caption: String(localized: "Sweep's panel and windows match your Mac's light or dark appearance."))
                }
            }
        }
    }
}

// MARK: - Features overview

struct FeaturesOverviewPage: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject private var state = SettingsState.shared

    private struct Group {
        let title: String
        let icon: String
        let moduleIDs: [String]
    }

    private let groups = [
        Group(title: String(localized: "Sweep"), icon: "wind",
              moduleIDs: ["desktop-sweep", "app-sweep"]),
        Group(title: String(localized: "Utilities"), icon: "wrench.and.screwdriver",
              moduleIDs: ["clipboard"]),
    ]

    var body: some View {
        SettingsPageScaffold(title: String(localized: "Features"),
                             subtitle: String(localized: "Everything is off until you turn it on. A feature that is off loads nothing at all.")) {
            // Summary header
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(registry.enabledIDs.count) of \(registry.modules.count) features enabled")
                            .font(.headline)
                        Spacer()
                        Button(String(localized: "Enable all")) {
                            for module in registry.modules { registry.setEnabled(module.id, true) }
                        }
                        .controlSize(.small)
                        Button(String(localized: "Disable all")) {
                            for module in registry.modules { registry.setEnabled(module.id, false) }
                        }
                        .controlSize(.small)
                    }
                    ProgressView(value: Double(registry.enabledIDs.count),
                                 total: Double(max(registry.modules.count, 1)))
                        .tint(.accentColor)
                }
                .padding(14)
            }

            ForEach(groups, id: \.title) { group in
                let modules = group.moduleIDs.compactMap { id in
                    registry.modules.first(where: { $0.id == id })
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: group.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                            .frame(width: 24, height: 24)
                            .background(Color.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                        Text(group.title).font(.headline)
                        Spacer()
                        Text("\(modules.filter { registry.isEnabled($0.id) }.count)/\(modules.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SettingsCard {
                        ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                            if index > 0 { CardDivider() }
                            SettingsRow(icon: FeatureUI.icon(for: module.id),
                                        tint: FeatureUI.tint(for: module.id),
                                        title: module.name,
                                        caption: rowCaption(for: module)) {
                                HStack(spacing: 10) {
                                    Button {
                                        state.selection = .feature(module.id)
                                    } label: {
                                        HStack(spacing: 2) {
                                            Text("Options")
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9, weight: .semibold))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)

                                    FeatureToggleControl(registry: registry, module: module)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func rowCaption(for module: FeatureModule) -> String {
        // FR-7.2: a missing permission is shown, never a silent failure.
        if registry.isEnabled(module.id),
           !PermissionExplainers.pendingKinds(for: module).isEmpty {
            return module.summary + " " + String(localized: "⚠ May be missing a permission — open its options.")
        }
        return module.summary
    }
}

// MARK: - Feature detail

struct FeatureDetailPage: View {
    @ObservedObject var registry: FeatureRegistry
    let module: FeatureModule

    var body: some View {
        SettingsPageScaffold(title: module.name, subtitle: module.summary) {
            SettingsCard {
                SettingsRow(icon: FeatureUI.icon(for: module.id),
                            tint: FeatureUI.tint(for: module.id),
                            title: module.name,
                            caption: registry.isEnabled(module.id)
                                ? String(localized: "On — shown in the menu bar panel.")
                                : String(localized: "Off — loads nothing at all.")) {
                    FeatureToggleControl(registry: registry, module: module)
                }
            }

            if let options = module.makeSettingsView() {
                options
            }
        }
    }
}

// MARK: - About

struct AboutPage: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPageScaffold(title: String(localized: "About")) {
            SettingsCard {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("Sweep").font(.title.weight(.semibold))
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("A small collection of everyday utilities.\nEverything runs locally — no network, no analytics, no accounts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }
}

// MARK: - Window controller

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Sweep Settings")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 560)
        window.contentViewController = NSHostingController(
            rootView: SettingsView(registry: .shared)
        )
        window.center()
        self.init(window: window)
    }
}
