import SwiftUI
import AppKit

// MARK: - Controls (home) page

/// Landing page: Desktop Sweep, App Sweep, and a shortcut into Clipboard.
struct ControlsHomePage: View {
    @ObservedObject var registry: FeatureRegistry
    let onOpenPage: (IslandPage) -> Void

    @ObservedObject var coordinator = SweepCoordinator.shared
    @ObservedObject var desktop = DesktopSweepModule.shared
    @ObservedObject var apps = AppSweepModule.shared
    @ObservedObject var clipboard = ClipboardModule.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                sweepCard
                    .frame(maxWidth: .infinity)
                clipboardCard
                    .frame(width: 190)
            }
            if registry.isEnabled("desktop-sweep") || registry.isEnabled("app-sweep") {
                quickActions
            }
            Spacer(minLength: 0)
        }
    }

    private var sweepCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: coordinator.isSwept ? "wind.circle.fill" : "wind")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(coordinator.isSwept ? Color.orange : .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.isSwept ? String(localized: "Swept") : String(localized: "Ready"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(sweepCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
            Button {
                coordinator.toggleSweepAll()
            } label: {
                Text(coordinator.isSwept ? String(localized: "Restore") : String(localized: "Sweep All"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!registry.isEnabled("desktop-sweep") && !registry.isEnabled("app-sweep"))
        }
        .islandCard()
    }

    private var sweepCaption: String {
        if coordinator.isSwept {
            var parts: [String] = []
            if desktop.isSwept { parts.append(String(localized: "Desktop hidden")) }
            if apps.isSwept { parts.append(String(localized: "Apps closed")) }
            return parts.isEmpty
                ? String(localized: "Something is swept away.")
                : parts.joined(separator: " · ")
        }
        return String(localized: "Hide the desktop and tuck apps away in one go.")
    }

    private var clipboardCard: some View {
        Button { onOpenPage(.clipboard) } label: {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.teal)
                    Text("Clipboard")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                    Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
                Text(clipboardSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
        }
        .islandCard()
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!registry.isEnabled("clipboard"))
        .opacity(registry.isEnabled("clipboard") ? 1 : 0.45)
    }

    private var clipboardSummary: String {
        guard registry.isEnabled("clipboard") else {
            return String(localized: "Turn on Clipboard History in Settings.")
        }
        if let first = clipboard.clippings.first {
            return first.preview
        }
        return String(localized: "Nothing copied yet.")
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            if registry.isEnabled("desktop-sweep") {
                featureToggle(
                    title: String(localized: "Desktop"),
                    icon: "menubar.dock.rectangle",
                    isOn: desktop.isSwept) {
                    if desktop.isSwept { desktop.restore() } else { desktop.sweep() }
                }
            }
            if registry.isEnabled("app-sweep") {
                featureToggle(
                    title: String(localized: "Apps"),
                    icon: "macwindow.on.rectangle",
                    isOn: apps.isSwept) {
                    if apps.isSwept { apps.restore() } else { apps.sweep() }
                }
            }
            featureToggle(
                title: String(localized: "Clipboard"),
                icon: "doc.on.clipboard",
                isOn: false) {
                onOpenPage(.clipboard)
            }
        }
    }

    private func featureToggle(title: String, icon: String, isOn: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isOn ? Color.orange : .white)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick access grid

struct IslandGridPage: View {
    @ObservedObject var registry: FeatureRegistry
    let onOpenPage: (IslandPage) -> Void
    let onOpenSettings: () -> Void

    @ObservedObject var prefs = IslandPrefs.shared

    private var pages: [IslandPage] {
        [.controls, .clipboard].filter { page in
            if page == .controls { return true }
            guard let tile = IslandTile.allCases.first(where: { $0.page == page }) else { return true }
            return prefs.showsTile(tile)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                      spacing: 10) {
                ForEach(pages) { page in
                    tile(page)
                }
            }
            .padding(.top, 2)
        }
    }

    private func tile(_ page: IslandPage) -> some View {
        Button { onOpenPage(page) } label: {
            VStack(spacing: 7) {
                Image(systemName: page.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(page.accent)
                    .frame(height: 24)
                Text(page.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(page.shortcutDisplay ?? " ")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Clipboard page

struct IslandClipboardPage: View {
    let onCollapse: () -> Void

    @ObservedObject var module = ClipboardModule.shared
    @ObservedObject var hotkeys = HotkeyManager.shared
    @State private var pickedID: UUID?
    @State private var saveMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(countText).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCollapse()
                    ClipboardBezelController.shared.showOrAdvance()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.stack").font(.system(size: 10, weight: .semibold))
                        Text(bezelLabel).font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
                if !module.clippings.isEmpty {
                    Button { module.clearHistory() } label: {
                        Text("Clear").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.white.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Toggle(isOn: $module.screenshotsToClipboardOnly) {
                    Text(String(localized: "Clipboard-only shots"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.teal)
                if module.screenshotsToClipboardOnly && module.screenshotModeOverridden {
                    Button(String(localized: "Fix")) {
                        module.reassertScreenshotClipboardTarget()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)

            if module.screenshotsToClipboardOnly {
                Text(module.screenshotModeOverridden
                      ? String(localized: "Screenshot Options changed the destination.")
                      : String(localized: "⌘⇧4 copies only — right-click an image to save."))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(module.screenshotModeOverridden ? Color.orange : .secondary)
            }

            if let saveMessage {
                Text(saveMessage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            if module.clippings.isEmpty {
                islandEmptyState(icon: "doc.on.clipboard",
                                 title: String(localized: "Nothing copied yet"),
                                 caption: module.screenshotsToClipboardOnly
                                    ? String(localized: "Take a screenshot — it stays on the clipboard and shows up here.")
                                    : String(localized: "Everything you copy appears here."))
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(module.clippings.prefix(6))) { clipping in row(clipping) }
                    }
                }
            }
        }
    }

    private var countText: String {
        let count = module.clippings.count
        return count == 1 ? String(localized: "1 clipping") : String(localized: "\(count) clippings")
    }

    private var bezelLabel: String {
        if let display = hotkeys.shortcut(for: .clipboard)?.display {
            return String(localized: "Bezel \(display)")
        }
        return String(localized: "Open bezel")
    }

    private func row(_ clipping: Clipping) -> some View {
        Button {
            module.pick(clipping)
            pickedID = clipping.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if pickedID == clipping.id { pickedID = nil }
            }
        } label: {
            HStack(spacing: 9) {
                thumbnail(clipping)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clipping.preview).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(subtitle(clipping)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: pickedID == clipping.id ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(pickedID == clipping.id ? Color.orange : .secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(String(localized: "Copy")) {
                module.pick(clipping)
            }
            if clipping.kind == .image {
                Button(String(localized: "Save…")) {
                    saveAs(clipping)
                }
                Button(String(localized: "Save to Screenshots")) {
                    saveToScreenshots(clipping)
                }
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                module.delete(clipping)
            }
        }
    }

    private func saveAs(_ clipping: Clipping) {
        onCollapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            do {
                if let url = try module.saveAs(clipping) {
                    saveMessage = String(localized: "Saved to \(url.lastPathComponent)")
                }
            } catch {
                saveMessage = error.localizedDescription
            }
            clearSaveMessageLater()
        }
    }

    private func saveToScreenshots(_ clipping: Clipping) {
        do {
            let url = try module.saveToScreenshots(clipping)
            saveMessage = String(localized: "Saved to \(url.lastPathComponent)")
        } catch {
            saveMessage = error.localizedDescription
        }
        clearSaveMessageLater()
    }

    private func clearSaveMessageLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            saveMessage = nil
        }
    }

    @ViewBuilder
    private func thumbnail(_ clipping: Clipping) -> some View {
        if clipping.kind == .image, let image = module.thumbnail(for: clipping, maxPixel: 96) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if let image = module.thumbnail(for: clipping, maxPixel: 96) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: clipping.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func subtitle(_ clipping: Clipping) -> String {
        var parts: [String] = []
        if let app = clipping.sourceApp { parts.append(app) }
        parts.append(clipping.date.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shared empty/permission states

@ViewBuilder
func islandEmptyState(icon: String, title: String, caption: String,
                      actionLabel: String? = nil, action: (() -> Void)? = nil) -> some View {
    VStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white.opacity(0.07)).frame(width: 64, height: 64)
            .overlay(Image(systemName: icon).font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary))
        Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
        Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        if let actionLabel, let action {
            Button(action: action) {
                Text(actionLabel).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.buttonStyle(.plain).padding(.top, 2)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

@ViewBuilder
func islandPermissionState(icon: String, caption: String,
                           actionLabel: String, action: @escaping () -> Void) -> some View {
    VStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
        Text(caption).font(.system(size: 13)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        Button(action: action) {
            Text(actionLabel).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }.buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 20)
}
