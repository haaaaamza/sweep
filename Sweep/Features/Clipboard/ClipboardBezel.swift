import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Bezel styles

/// The selectable looks for the ⌘⇧V overlay (Clipboard History → Options).
enum BezelStyle: String, CaseIterable, Identifiable {
    case refined
    case classic
    case deck
    case filmstrip
    case list
    case bottomBar
    case pill
    case sidebar
    case grid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .refined: return String(localized: "Refined HUD")
        case .classic: return String(localized: "Flycut Classic")
        case .deck: return String(localized: "Card Deck")
        case .filmstrip: return String(localized: "Filmstrip")
        case .list: return String(localized: "List + Preview")
        case .bottomBar: return String(localized: "Bottom Bar")
        case .pill: return String(localized: "Compact Pill")
        case .sidebar: return String(localized: "Sidebar")
        case .grid: return String(localized: "Grid Picker")
        }
    }

    var blurb: String {
        switch self {
        case .refined:
            return String(localized: "Header, kind badge, thumbnail strip and key hints — the balanced default.")
        case .classic:
            return String(localized: "Radically minimal, faithful to the original Flycut: source, the clipping, a counter.")
        case .deck:
            return String(localized: "The previous and next clippings peek from the sides, cover-flow style.")
        case .filmstrip:
            return String(localized: "Big thumbnails are the interface; a slim preview sits above them.")
        case .list:
            return String(localized: "A vertical list with a preview pane — best for long histories and long text.")
        case .bottomBar:
            return String(localized: "A wide shelf of cards that slides up from the bottom of the screen.")
        case .pill:
            return String(localized: "A one-line capsule near the top of the screen, like a volume HUD.")
        case .sidebar:
            return String(localized: "The clipping front and center; app, time and size in a quiet right rail.")
        case .grid:
            return String(localized: "A 3×3 board of the last 9 clippings — press 1–9 to pick instantly.")
        }
    }

    var panelSize: CGSize {
        switch self {
        case .refined: return CGSize(width: 560, height: 400)
        case .classic: return CGSize(width: 480, height: 280)
        case .deck: return CGSize(width: 700, height: 360)
        case .filmstrip: return CGSize(width: 620, height: 310)
        case .list: return CGSize(width: 640, height: 360)
        case .bottomBar: return CGSize(width: 980, height: 250)
        case .pill: return CGSize(width: 560, height: 56)
        case .sidebar: return CGSize(width: 660, height: 340)
        case .grid: return CGSize(width: 560, height: 420)
        }
    }

    enum Placement { case center, top, bottom }

    var placement: Placement {
        switch self {
        case .pill: return .top
        case .bottomBar: return .bottom
        default: return .center
        }
    }

    /// Grid can only address what its 9 cells show.
    var navigableLimit: Int? { self == .grid ? 9 : nil }
}

// MARK: - Controller

/// The Flycut-style overlay: press the clipboard shortcut and it appears.
/// Pressing again (or ← → while holding modifiers) cycles; releasing the
/// modifiers (or Return) chooses the clipping. Escape cancels.
///
/// Keyboard input goes through the key panel only — no global monitors
/// (those need Input Monitoring and fail silently without it).
final class ClipboardBezelController: ObservableObject {
    static let shared = ClipboardBezelController()

    @Published private(set) var index = 0

    private var panel: ClipboardBezelPanel?
    private var isShowing = false
    /// Ignore modifier-release commits until this time (avoids flash-dismiss).
    private var ignoreReleaseUntil: Date = .distantPast
    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?

    var isVisible: Bool { isShowing }

    private var navigableCount: Int {
        let count = ClipboardModule.shared.clippings.count
        if let limit = ClipboardModule.shared.bezelStyle.navigableLimit {
            return min(count, limit)
        }
        return count
    }

    func showOrAdvance() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.showOrAdvance() }
            return
        }
        let module = ClipboardModule.shared
        guard module.isEnabled, !module.clippings.isEmpty else { return }
        if isShowing {
            advance(1)
        } else {
            index = 0
            show()
        }
    }

    func advance(_ delta: Int) {
        let count = navigableCount
        guard count > 0 else { return }
        let next = min(max(index + delta, 0), count - 1)
        guard next != index else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { index = next }
        prefetchThumbnails(around: next)
    }

    func select(_ newIndex: Int) {
        let count = navigableCount
        guard count > 0 else { return }
        let next = min(max(newIndex, 0), count - 1)
        guard next != index else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { index = next }
        prefetchThumbnails(around: next)
    }

    private func prefetchThumbnails(around center: Int) {
        let module = ClipboardModule.shared
        let items = module.clippings
        guard !items.isEmpty else { return }
        let lo = max(0, center - 2)
        let hi = min(items.count - 1, center + 2)
        let slice = Array(items[lo...hi])
        DispatchQueue.global(qos: .userInitiated).async {
            for clipping in slice {
                _ = module.thumbnail(for: clipping, maxPixel: 360)
            }
        }
    }

    func handleDigit(_ digit: Int) {
        let target = digit - 1
        guard target < navigableCount else { return }
        select(target)
        if ClipboardModule.shared.bezelStyle == .grid {
            commit()
        }
    }

    func commit() {
        guard isShowing else { return }
        let module = ClipboardModule.shared
        let clipping = module.clippings.indices.contains(index) ? module.clippings[index] : nil
        hide()
        if let clipping {
            DispatchQueue.main.async { module.pick(clipping) }
        }
    }

    func cancel() {
        hide()
    }

    /// Release ⌘⇧ (etc.) → choose & hide. Ignored during the open grace window.
    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard isShowing, Date() >= ignoreReleaseUntil else { return }
        let required = Self.requiredModifiers(of: .clipboard)
        guard !required.isEmpty else { return }
        if flags.intersection(required).isEmpty {
            commit()
        }
    }

    func handlePanelKeyDown(_ event: NSEvent) -> Bool {
        guard isScreenshotChord(event) else { return false }
        return capturePopupAndClose()
    }

    /// ⌘⇧3/4/5 while the popup is open: save a picture of this popup, then hide.
    /// The system screenshot tool cannot capture this panel, and swallowing the
    /// real key (or faking one) left the popup stuck with no image.
    func capturePopupAndClose() -> Bool {
        guard isShowing, let panel else { return false }
        panel.displayIfNeeded()
        guard let image = Self.image(of: panel), let png = Self.pngData(from: image) else { return false }
        hide()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        Self.writeScreenshotFile(png)
        return true
    }

    private static func image(of panel: NSWindow) -> NSImage? {
        let windowID = CGWindowID(panel.windowNumber)
        if let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]),
           cgImage.width > 1, cgImage.height > 1 {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        guard let view = panel.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func writeScreenshotFile(_ png: Data) {
        let folder = screenshotFolder()
        let stamp = screenshotStamp.string(from: Date())
        let url = folder.appendingPathComponent("Screenshot \(stamp).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch { }
    }

    private static let screenshotStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        return formatter
    }()

    private static func screenshotFolder() -> URL {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture")
        let raw = (domain?["location-screenshot"] as? String) ?? (domain?["location"] as? String)
        if let raw, !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private func isScreenshotChord(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.contains(.shift) else { return false }
        switch Int(event.keyCode) {
        case kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6:
            return true
        default:
            return false
        }
    }

    private func show() {
        if panel == nil {
            panel = ClipboardBezelPanel(controller: self)
        }
        guard let panel else { return }

        let style = ClipboardModule.shared.bezelStyle
        let size = style.panelSize
        panel.setContentSize(size)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let x = frame.midX - size.width / 2
            let y: CGFloat
            switch style.placement {
            case .center: y = frame.midY - size.height / 2 + frame.height * 0.08
            case .top: y = frame.maxY - size.height - 60
            case .bottom: y = frame.minY + 10
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        isShowing = true
        ignoreReleaseUntil = Date().addingTimeInterval(0.25)
        ClipboardModule.shared.setBezelPollingSuspended(true)
        panel.alphaValue = 1
        installLocalMonitors()
        panel.makeKeyAndOrderFront(nil)
        prefetchThumbnails(around: index)
    }

    private func hide() {
        removeLocalMonitors()
        isShowing = false
        ClipboardModule.shared.setBezelPollingSuspended(false)
        panel?.orderOut(nil)
    }

    private func installLocalMonitors() {
        removeLocalMonitors()
        // Local monitors run before SwiftUI. Returning nil for arrows stops
        // SwiftUI focus navigation from swallowing ← →.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShowing else { return event }
            if self.isScreenshotChord(event) {
                if self.capturePopupAndClose() { return nil }
                return event
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.cancel()
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.commit()
                return nil
            case kVK_LeftArrow, kVK_UpArrow:
                self.advance(-1)
                return nil
            case kVK_RightArrow, kVK_DownArrow:
                self.advance(1)
                return nil
            case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                 kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9:
                if let digit = ClipboardBezelPanel.digitKeyCodes[Int(event.keyCode)] {
                    self.handleDigit(digit)
                    return nil
                }
                return event
            default:
                return event
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsChanged(event.modifierFlags)
            return event
        }
    }

    private func removeLocalMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
    }

    private static func requiredModifiers(of slot: HotkeyManager.Slot) -> NSEvent.ModifierFlags {
        guard let shortcut = HotkeyManager.shared.shortcut(for: slot) else { return [] }
        var required: NSEvent.ModifierFlags = []
        if shortcut.carbonModifiers & UInt32(cmdKey) != 0 { required.insert(.command) }
        if shortcut.carbonModifiers & UInt32(optionKey) != 0 { required.insert(.option) }
        if shortcut.carbonModifiers & UInt32(controlKey) != 0 { required.insert(.control) }
        if shortcut.carbonModifiers & UInt32(shiftKey) != 0 { required.insert(.shift) }
        return required
    }
}

// MARK: - Panel

/// Borderless key panel: receives ← → / Esc / modifier releases while the
/// previous app stays visually frontmost.
final class ClipboardBezelPanel: NSPanel {
    private let controller: ClipboardBezelController

    static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3,
        kVK_ANSI_4: 4, kVK_ANSI_5: 5, kVK_ANSI_6: 6,
        kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    init(controller: ClipboardBezelController) {
        self.controller = controller
        super.init(contentRect: NSRect(origin: .zero, size: BezelStyle.refined.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Floating, not status-bar: status-bar windows are omitted from
        // screenshots and cover the selection UI, so ⌘⇧4 cannot capture them.
        level = .floating
        sharingType = .readOnly
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: ClipboardBezelView(controller: controller,
                                                                 module: .shared))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if controller.handlePanelKeyDown(event) { return }
        // Local monitor normally consumes nav keys first. Fallback only.
        switch Int(event.keyCode) {
        case kVK_Escape: controller.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter: controller.commit()
        case kVK_LeftArrow, kVK_UpArrow: controller.advance(-1)
        case kVK_RightArrow, kVK_DownArrow: controller.advance(1)
        default: super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        controller.flagsChanged(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    override func resignKey() {
        super.resignKey()
        // Don't auto-cancel here — releasing modifiers / Esc / Return owns
        // dismiss. resignKey fires often when the previous app stays active.
    }
}

// MARK: - Root view

struct ClipboardBezelView: View {
    @ObservedObject var controller: ClipboardBezelController
    @ObservedObject var module: ClipboardModule

    var body: some View {
        let style = module.bezelStyle
        let clippings = module.clippings
        let index = min(controller.index, max(clippings.count - 1, 0))
        let clipping = clippings.indices.contains(index) ? clippings[index] : nil

        Group {
            if let clipping {
                layout(style, clippings: clippings, clipping: clipping, index: index)
            } else {
                emptyState
            }
        }
        // No index animation — arrows must feel instant.
        .transaction { $0.animation = nil }
        .frame(width: style.panelSize.width, height: style.panelSize.height)
        .background(BezelBackground())
        .clipShape(RoundedRectangle(cornerRadius: style == .pill ? 28 : 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: style == .pill ? 28 : 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func layout(_ style: BezelStyle, clippings: [Clipping],
                        clipping: Clipping, index: Int) -> some View {
        switch style {
        case .refined:
            RefinedBezelLayout(module: module, controller: controller,
                               clippings: clippings, clipping: clipping, index: index)
        case .classic:
            ClassicBezelLayout(clipping: clipping, module: module,
                               index: index, count: clippings.count)
        case .deck:
            DeckBezelLayout(module: module, clippings: clippings, index: index)
        case .filmstrip:
            FilmstripBezelLayout(module: module, controller: controller,
                                 clippings: clippings, clipping: clipping, index: index)
        case .list:
            ListBezelLayout(module: module, controller: controller,
                            clippings: clippings, clipping: clipping, index: index)
        case .bottomBar:
            BottomBarBezelLayout(module: module, controller: controller,
                                 clippings: clippings, index: index)
        case .pill:
            PillBezelLayout(module: module, clipping: clipping,
                            index: index, count: clippings.count)
        case .sidebar:
            SidebarBezelLayout(module: module, controller: controller,
                               clippings: clippings, clipping: clipping, index: index)
        case .grid:
            GridBezelLayout(module: module, controller: controller,
                            clippings: clippings, index: index)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("Nothing copied yet")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared pieces

enum BezelUI {
    static func sourceIcon(for clipping: Clipping) -> NSImage {
        if let bundleID = clipping.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            ?? NSImage()
    }

    static var hints: String {
        let combo = HotkeyManager.shared.shortcut(for: .clipboard)?.display ?? "⌘⇧V"
        return String(localized: "\(combo) or ← → to cycle · release to choose · ⎋ cancel")
    }

    /// A window of indices around the selection, for strips and rails.
    static func window(count: Int, index: Int, size: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lower = max(0, min(index - size / 2, count - size))
        return lower..<min(count, lower + size)
    }
}

private struct BezelHeader: View {
    let clipping: Clipping

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: BezelUI.sourceIcon(for: clipping))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(clipping.sourceApp ?? String(localized: "Clipboard"))
                    .font(.headline)
                HStack(spacing: 4) {
                    Text(clipping.date, format: .relative(presentation: .named))
                    Text("·")
                    Text(clipping.date.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            BezelKindBadge(clipping: clipping)
        }
    }
}

private struct BezelKindBadge: View {
    let clipping: Clipping

    var body: some View {
        let label: String
        let symbol: String
        switch clipping.kind {
        case .image:
            symbol = "photo"
            if let size = clipping.imagePixelSize {
                label = "\(Int(size.width)) × \(Int(size.height))"
            } else {
                label = String(localized: "Image")
            }
        case .text:
            symbol = clipping.previewImageFiles.isEmpty ? "textformat" : "photo.on.rectangle"
            let shown = clipping.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if shown.isEmpty {
                label = clipping.preview
            } else {
                label = String(localized: "\(shown.count) characters")
            }
        }
        return Label(label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary.opacity(0.6)))
    }
}

private struct BezelContent: View {
    @ObservedObject var module: ClipboardModule
    let clipping: Clipping
    var compact = false

    var body: some View {
        switch clipping.kind {
        case .image:
            imageBody
        case .text:
            textBody
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        if let image = module.thumbnail(for: clipping, maxPixel: compact ? 720 : 900) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )
        } else {
            Label(clipping.preview, systemImage: "photo")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var textBody: some View {
        let shown = clipping.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = module.previewThumbnails(for: clipping, maxPixel: compact ? 360 : 720)
        return VStack(spacing: 8) {
            if !images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: compact ? 72 : 140)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if shown.isEmpty {
                Text(clipping.preview)
                    .font(compact ? .body.weight(.medium) : .title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: images.isEmpty ? .infinity : nil)
            } else if shown.count <= 140 && !shown.contains("\n") {
                Text(shown)
                    .font(compact ? .body.weight(.medium) : .title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(shown)
                    .font(.callout)
                    .lineLimit(compact ? 6 : 10)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BezelThumb: View {
    @ObservedObject var module: ClipboardModule
    let clipping: Clipping
    let selected: Bool
    var size = CGSize(width: 44, height: 32)
    var fontSize: CGFloat = 6

    var body: some View {
        Group {
            if let image = module.thumbnail(for: clipping, maxPixel: 180) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(clipping.preview)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.quaternary.opacity(0.5))
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.12),
                              lineWidth: selected ? 2 : 1)
        )
        .opacity(selected ? 1 : 0.6)
        .scaleEffect(selected ? 1.08 : 1)
    }
}

private struct BezelFilmstrip: View {
    @ObservedObject var module: ClipboardModule
    let controller: ClipboardBezelController
    let clippings: [Clipping]
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(BezelUI.window(count: clippings.count, index: index, size: 9), id: \.self) { i in
                BezelThumb(module: module, clipping: clippings[i], selected: i == index)
                    .onTapGesture { controller.select(i) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BezelFooter: View {
    let index: Int
    let count: Int

    var body: some View {
        HStack {
            Text("\(index + 1) of \(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Text(BezelUI.hints)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - 1. Refined HUD

private struct RefinedBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let controller: ClipboardBezelController
    let clippings: [Clipping]
    let clipping: Clipping
    let index: Int

    var body: some View {
        VStack(spacing: 14) {
            BezelHeader(clipping: clipping)
            BezelContent(module: module, clipping: clipping)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            BezelFilmstrip(module: module, controller: controller,
                           clippings: clippings, index: index)
            BezelFooter(index: index, count: clippings.count)
        }
        .padding(18)
    }
}

// MARK: - 2. Flycut Classic

private struct ClassicBezelLayout: View {
    let clipping: Clipping
    @ObservedObject var module: ClipboardModule
    let index: Int
    let count: Int

    init(clipping: Clipping, module: ClipboardModule, index: Int, count: Int) {
        self.clipping = clipping
        self.module = module
        self.index = index
        self.count = count
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 7) {
                    Image(nsImage: BezelUI.sourceIcon(for: clipping))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(clipping.sourceApp ?? String(localized: "Clipboard"))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                Text(clipping.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            BezelContent(module: module, clipping: clipping)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("\(index + 1) of \(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.3)))
        }
        .padding(22)
    }
}

// MARK: - 3. Card Deck

private struct DeckBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let clippings: [Clipping]
    let index: Int

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if clippings.count > 2 {
                    card(at: (index - 1 + clippings.count) % clippings.count)
                        .scaleEffect(0.84)
                        .offset(x: -210)
                        .opacity(0.45)
                }
                if clippings.count > 1 {
                    card(at: (index + 1) % clippings.count)
                        .scaleEffect(0.84)
                        .offset(x: 210)
                        .opacity(0.45)
                }
                card(at: index)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 5) {
                ForEach(BezelUI.window(count: clippings.count, index: index, size: 12), id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.accentColor : .white.opacity(0.25))
                        .frame(width: i == index ? 18 : 6, height: 6)
                }
            }
        }
        .padding(16)
    }

    private func card(at i: Int) -> some View {
        let clipping = clippings[i]
        return VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(nsImage: BezelUI.sourceIcon(for: clipping))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(clipping.sourceApp ?? String(localized: "Clipboard"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(clipping.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            BezelContent(module: module, clipping: clipping, compact: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .frame(width: 400, height: 260)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(i == index ? Color.accentColor.opacity(0.5) : .white.opacity(0.1),
                              lineWidth: 1)
        )
    }
}

// MARK: - 4. Filmstrip

private struct FilmstripBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let controller: ClipboardBezelController
    let clippings: [Clipping]
    let clipping: Clipping
    let index: Int

    var body: some View {
        VStack(spacing: 14) {
            BezelContent(module: module, clipping: clipping, compact: true)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(BezelUI.window(count: clippings.count, index: index, size: 5), id: \.self) { i in
                    BezelThumb(module: module, clipping: clippings[i], selected: i == index,
                               size: i == index ? CGSize(width: 104, height: 78)
                                                : CGSize(width: 86, height: 64),
                               fontSize: 8)
                        .onTapGesture { controller.select(i) }
                }
            }
            HStack {
                HStack(spacing: 7) {
                    Image(nsImage: BezelUI.sourceIcon(for: clipping))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(clipping.sourceApp ?? String(localized: "Clipboard"))
                        .font(.caption.weight(.semibold))
                    Text(clipping.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(index + 1) of \(clippings.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
    }
}

// MARK: - 5. List + Preview

private struct ListBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let controller: ClipboardBezelController
    let clippings: [Clipping]
    let clipping: Clipping
    let index: Int

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(BezelUI.window(count: clippings.count, index: index, size: 9), id: \.self) { i in
                    row(at: i)
                        .onTapGesture { controller.select(i) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 250)

            Divider().overlay(.white.opacity(0.1))

            VStack(spacing: 12) {
                BezelHeader(clipping: clipping)
                BezelContent(module: module, clipping: clipping, compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BezelFooter(index: index, count: clippings.count)
            }
            .padding(14)
        }
    }

    private func row(at i: Int) -> some View {
        let item = clippings[i]
        return HStack(spacing: 8) {
            Text("\(i + 1)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 14, alignment: .trailing)
            if let image = module.thumbnail(for: item, maxPixel: 96) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 16)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text(item.preview)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .foregroundStyle(i == index ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .background(
            i == index ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - 6. Bottom Bar

private struct BottomBarBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let controller: ClipboardBezelController
    let clippings: [Clipping]
    let index: Int

    private let cardCorner: CGFloat = 12
    private let contentCorner: CGFloat = 6
    private let cardSpacing: CGFloat = 12

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let visible = BezelUI.window(count: clippings.count, index: index, size: 5)
                // Size from content aspect only — selection must not resize cards
                // (that reflow is what felt glitchy on every arrow).
                let raw = visible.map { idealCardSize(for: clippings[$0]) }
                let widths = fittedWidths(raw.map(\.width), in: geo.size.width)
                HStack(alignment: .center, spacing: cardSpacing) {
                    ForEach(Array(visible.enumerated()), id: \.element) { offset, i in
                        card(at: i, size: CGSize(width: widths[offset], height: raw[offset].height))
                            .onTapGesture { controller.select(i) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            BezelFooter(index: index, count: clippings.count)
        }
        .padding(16)
    }

    private func card(at i: Int, size: CGSize) -> some View {
        let item = clippings[i]
        let selected = i == index
        let previews = module.previewThumbnails(for: item, maxPixel: 360)
        let caption = item.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(nsImage: BezelUI.sourceIcon(for: item))
                    .resizable()
                    .frame(width: 13, height: 13)
                Text(item.sourceApp ?? String(localized: "Clipboard"))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(item.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Group {
                if item.kind == .image, let image = module.thumbnail(for: item, maxPixel: 360) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: contentCorner))
                } else if !previews.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 58)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: contentCorner))
                            }
                        }
                        if !caption.isEmpty {
                            Text(caption)
                                .font(.caption2)
                                .lineLimit(3)
                        }
                    }
                } else {
                    Text(caption.isEmpty ? item.preview : caption)
                        .font(.caption2)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .padding(9)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.quaternary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: cardCorner)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.12),
                              lineWidth: selected ? 2 : 1)
        )
        .opacity(selected ? 1 : 0.72)
    }

    /// Card width follows image aspect; height is stable across selection.
    private func idealCardSize(for item: Clipping) -> CGSize {
        let height: CGFloat = 148
        let pad: CGFloat = 18
        let header: CGFloat = 18
        let contentHeight = max(1, height - pad - header)
        if item.kind == .image, let pixels = item.imagePixelSize, pixels.height > 0 {
            let aspect = pixels.width / pixels.height
            let contentWidth = contentHeight * aspect
            let width = min(260, max(108, contentWidth + pad))
            return CGSize(width: width, height: height)
        }
        if !item.previewImageFiles.isEmpty {
            return CGSize(width: 220, height: height)
        }
        return CGSize(width: 160, height: height)
    }

    private func fittedWidths(_ widths: [CGFloat], in available: CGFloat) -> [CGFloat] {
        guard !widths.isEmpty else { return widths }
        let gaps = cardSpacing * CGFloat(widths.count - 1)
        let total = widths.reduce(0, +) + gaps
        guard total > available, total > 0 else { return widths }
        let scale = (available - gaps) / (total - gaps)
        return widths.map { max(88, $0 * scale) }
    }
}

// MARK: - 7. Compact Pill

private struct PillBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let clipping: Clipping
    let index: Int
    let count: Int

    init(module: ClipboardModule, clipping: Clipping, index: Int, count: Int) {
        self.module = module
        self.clipping = clipping
        self.index = index
        self.count = count
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: BezelUI.sourceIcon(for: clipping))
                .resizable()
                .frame(width: 20, height: 20)
            if let image = module.thumbnail(for: clipping, maxPixel: 120) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 42, height: 28)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(clipping.preview)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            } else {
                Text(clipping.preview)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(clipping.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 4) {
                ForEach(BezelUI.window(count: count, index: index, size: 9), id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.accentColor : .white.opacity(0.25))
                        .frame(width: i == index ? 16 : 5, height: 5)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 8. Sidebar

private struct SidebarBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let controller: ClipboardBezelController
    let clippings: [Clipping]
    let clipping: Clipping
    let index: Int

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                BezelContent(module: module, clipping: clipping)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                BezelFilmstrip(module: module, controller: controller,
                               clippings: clippings, index: index)
            }
            .padding(16)

            Divider().overlay(.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(nsImage: BezelUI.sourceIcon(for: clipping))
                        .resizable()
                        .frame(width: 22, height: 22)
                    Text(clipping.sourceApp ?? String(localized: "Clipboard"))
                        .font(.subheadline.weight(.semibold))
                }
                metaRow(String(localized: "Copied"),
                        clipping.date.formatted(date: .abbreviated, time: .shortened))
                metaRow(String(localized: "Kind"),
                        clipping.kind == .image ? String(localized: "Image") : String(localized: "Plain text"))
                metaRow(String(localized: "Size"), sizeText)
                metaRow(String(localized: "Position"), "\(index + 1) of \(clippings.count)")
                Spacer()
                Text(BezelUI.hints)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(width: 185)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(.black.opacity(0.15))
        }
    }

    private var sizeText: String {
        if clipping.kind == .image, let size = clipping.imagePixelSize {
            return "\(Int(size.width)) × \(Int(size.height))"
        }
        return String(localized: "\(clipping.text.count) characters")
    }

    private func metaRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 9. Grid Picker

private struct GridBezelLayout: View {
    @ObservedObject var module: ClipboardModule
    let controller: ClipboardBezelController
    let clippings: [Clipping]
    let index: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(clippings.prefix(9).enumerated()), id: \.element.id) { i, item in
                    cell(item, number: i + 1, selected: i == index)
                        .onTapGesture {
                            controller.select(i)
                            controller.commit()
                        }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("Press 1–9 to pick instantly · arrows + release also work")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(clippings.count) remembered")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func cell(_ item: Clipping, number: Int, selected: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image = module.thumbnail(for: item, maxPixel: 360) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Text(item.visibleText.isEmpty ? item.preview : item.visibleText)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .padding(8)
                        .padding(.top, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .padding(5)
        }
        .frame(height: 100)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.45))
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.12),
                              lineWidth: selected ? 2 : 1)
        )
        .opacity(selected ? 1 : 0.75)
    }
}

// MARK: - Settings previews

/// A tiny schematic mockup of a bezel style, drawn over a mini "wallpaper",
/// shown in the style picker so the user can see each design before choosing.
struct BezelStylePreview: View {
    let style: BezelStyle

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.17, green: 0.30, blue: 0.26),
                                    Color(red: 0.36, green: 0.46, blue: 0.30),
                                    Color(red: 0.13, green: 0.25, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            schematic
        }
        .frame(width: 148, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: tiny building blocks

    private func hud<Content: View>(_ width: CGFloat, _ height: CGFloat,
                                    radius: CGFloat = 7,
                                    @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(5)
            .frame(width: width, height: height)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    private func bar(_ w: CGFloat, _ h: CGFloat = 3, _ opacity: Double = 0.45) -> some View {
        Capsule().fill(.white.opacity(opacity)).frame(width: w, height: h)
    }

    private func appDot(_ s: CGFloat = 6) -> some View {
        RoundedRectangle(cornerRadius: s * 0.3)
            .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.55, blue: 1),
                                          Color(red: 0.11, green: 0.37, blue: 0.82)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: s, height: s)
    }

    private var contentBlock: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white.opacity(0.12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thumb(_ selected: Bool, w: CGFloat = 13, h: CGFloat = 9) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(selected ? 0.4 : 0.18))
            .frame(width: w, height: h)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1))
    }

    private func dotRow(_ count: Int, selected: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == selected ? Color.accentColor : .white.opacity(0.3))
                    .frame(width: i == selected ? 8 : 3, height: 3)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 3) {
            appDot()
            VStack(alignment: .leading, spacing: 2) { bar(24, 3, 0.6); bar(16, 2, 0.3) }
            Spacer(minLength: 0)
            bar(18, 5, 0.2)
        }
    }

    // MARK: schematics

    @ViewBuilder
    private var schematic: some View {
        switch style {
        case .refined:
            hud(110, 74) {
                VStack(spacing: 4) {
                    headerRow
                    contentBlock
                    HStack(spacing: 2) {
                        thumb(false); thumb(false); thumb(true); thumb(false); thumb(false)
                    }
                    HStack { bar(10, 2, 0.3); Spacer(); bar(28, 2, 0.2) }
                }
            }
        case .classic:
            hud(96, 64) {
                VStack(spacing: 4) {
                    HStack { HStack(spacing: 2) { appDot(5); bar(18, 3, 0.6) }; Spacer(); bar(12, 2, 0.3) }
                    VStack(alignment: .leading, spacing: 3) {
                        bar(70, 4, 0.55); bar(52, 4, 0.55); bar(60, 4, 0.55)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    bar(20, 5, 0.25)
                }
            }
        case .deck:
            ZStack {
                hud(52, 50) { contentBlock }.offset(x: -38).opacity(0.5).scaleEffect(0.85)
                hud(52, 50) { contentBlock }.offset(x: 38).opacity(0.5).scaleEffect(0.85)
                hud(58, 56) {
                    VStack(spacing: 3) {
                        HStack(spacing: 2) { appDot(4); bar(14, 2, 0.5); Spacer() }
                        contentBlock
                    }
                }
                dotRow(7, selected: 3).offset(y: 36)
            }
        case .filmstrip:
            hud(118, 70) {
                VStack(spacing: 4) {
                    contentBlock.frame(height: 18)
                    HStack(alignment: .bottom, spacing: 3) {
                        thumb(false, w: 18, h: 13); thumb(false, w: 18, h: 13)
                        thumb(true, w: 24, h: 18)
                        thumb(false, w: 18, h: 13); thumb(false, w: 18, h: 13)
                    }
                    HStack { HStack(spacing: 2) { appDot(4); bar(14, 2, 0.4) }; Spacer(); bar(10, 2, 0.3) }
                }
            }
        case .list:
            hud(118, 72) {
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        bar(36, 4, 0.2)
                        Capsule().fill(Color.accentColor.opacity(0.5)).frame(width: 40, height: 5)
                        bar(34, 4, 0.2); bar(38, 4, 0.2); bar(32, 4, 0.2)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 42)
                    VStack(spacing: 3) {
                        headerRow
                        contentBlock
                    }
                }
            }
        case .bottomBar:
            VStack {
                Spacer()
                hud(136, 42, radius: 6) {
                    HStack(alignment: .bottom, spacing: 3) {
                        thumb(false, w: 22, h: 24); thumb(false, w: 22, h: 24)
                        thumb(true, w: 24, h: 30)
                        thumb(false, w: 22, h: 24); thumb(false, w: 22, h: 24)
                    }
                }
                .offset(y: 3)
            }
        case .pill:
            VStack {
                hud(110, 18, radius: 9) {
                    HStack(spacing: 3) {
                        appDot(5)
                        bar(40, 3, 0.55)
                        Spacer(minLength: 0)
                        dotRow(5, selected: 2)
                    }
                }
                .padding(.top, 12)
                Spacer()
            }
        case .sidebar:
            hud(118, 70) {
                HStack(spacing: 4) {
                    VStack(spacing: 3) {
                        contentBlock
                        HStack(spacing: 2) { thumb(false); thumb(true); thumb(false) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 2) { appDot(4); bar(12, 2, 0.5) }
                        bar(20, 2, 0.25); bar(16, 2, 0.25); bar(22, 2, 0.25); bar(14, 2, 0.25)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 28)
                }
            }
        case .grid:
            hud(96, 74) {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { col in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.white.opacity(row == 0 && col == 1 ? 0.4 : 0.15))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .overlay(RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(row == 0 && col == 1 ? Color.accentColor : .clear,
                                                      lineWidth: 1))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Background

/// HUD-style translucency behind the bezel.
private struct BezelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
