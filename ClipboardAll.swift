// ClipboardAll.swift
//
// One copy of every clipboard-specific source file in Sweep.
// This file sits next to the Xcode project, not inside Sweep/, so it is
// not compiled. The app still builds from the originals:
//   Sweep/Features/Clipboard/ClipboardModule.swift
//   Sweep/Features/Clipboard/ClipboardBezel.swift
//   Sweep/Views/IslandPages.swift  (IslandClipboardPage)
//
// Wired in from elsewhere:
//   AppDelegate registers ClipboardModule.shared and sets
//   HotkeyManager.shared.clipboardAction to ClipboardBezelController.shared.showOrAdvance().
//   HotkeyManager.Slot.clipboard defaults to ⌘⇧V (clipboard.shortcut).
//   Dynamic Island shows IslandClipboardPage when the clipboard page is open.


// MARK: - ClipboardModule.swift

import SwiftUI
import AppKit
import Carbon.HIToolbox
import CryptoKit

extension Notification.Name {
    /// Posted when a view wants the menu bar panel closed (e.g. before a
    /// clipboard paste, so the previous app regains focus).
    static let sweepClosePanel = Notification.Name("sweepClosePanel")
}

/// One remembered clipboard entry: text, or an image (Flycut++).
struct Clipping: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    let text: String            // the text, or "" for images
    let imageFile: String?      // PNG file name in the images folder
    let imagePixelSize: CGSize?
    let contentHash: String     // dedupe key (text, or SHA-256 of image data)
    var date: Date
    var sourceApp: String?
    var sourceBundleID: String?

    init(text: String, sourceApp: String?, sourceBundleID: String?) {
        self.id = UUID()
        self.kind = .text
        self.text = text
        self.imageFile = nil
        self.imagePixelSize = nil
        self.contentHash = text.sha256
        self.date = Date()
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
    }

    init(imageFile: String, pixelSize: CGSize, contentHash: String,
         sourceApp: String?, sourceBundleID: String?) {
        self.id = UUID()
        self.kind = .image
        self.text = ""
        self.imageFile = imageFile
        self.imagePixelSize = pixelSize
        self.contentHash = contentHash
        self.date = Date()
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
    }

    /// Tolerant decoding: entries saved by older builds were text-only.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        imageFile = try container.decodeIfPresent(String.self, forKey: .imageFile)
        imagePixelSize = try container.decodeIfPresent(CGSize.self, forKey: .imagePixelSize)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? text.sha256
        date = try container.decode(Date.self, forKey: .date)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
    }

    /// Single-line preview for the panel card and lists.
    var preview: String {
        if kind == .image {
            if let size = imagePixelSize {
                return String(localized: "Image · \(Int(size.width))×\(Int(size.height))")
            }
            return String(localized: "Image")
        }
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 60 ? String(collapsed.prefix(60)) + "…" : collapsed
    }
}

extension String {
    var sha256: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Flycut-style clipboard history. While enabled, the general pasteboard is
/// polled for new text and image clippings; the global shortcut shows a
/// translucent bezel to cycle through them. Password-manager content marked
/// transient/concealed is never recorded. Disabled = zero resources.
final class ClipboardModule: NSObject, ObservableObject, FeatureModule {
    static let shared = ClipboardModule()

    let id = "clipboard"
    let name = String(localized: "Clipboard History")
    let summary = String(localized: "Remember what you copy — text and images — and paste any of it back, anywhere.")
    let requiredPermissions: [PermissionKind] = []

    /// Pasteboard marker types (nspasteboard.org) that must never be recorded.
    private static let skippedTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
    ]
    /// Clippings larger than these are skipped/truncated when stored.
    private static let maxClippingLength = 100_000
    private static let maxImageBytes = 50_000_000

    // MARK: - State

    @Published private(set) var clippings: [Clipping] = []

    private let imageCache = NSCache<NSString, NSImage>()

    // MARK: - Options (persisted)

    @Published var historyLimit: Int {
        didSet {
            UserDefaults.standard.set(historyLimit, forKey: "clipboard.historyLimit")
            trimAndSave()
        }
    }
    /// Keep the history on disk so it survives relaunches.
    @Published var rememberAcrossLaunches: Bool {
        didSet {
            UserDefaults.standard.set(rememberAcrossLaunches, forKey: "clipboard.remember")
            rememberAcrossLaunches ? save() : deleteHistoryFile()
        }
    }
    /// After picking a clipping, simulate ⌘V in the active app (needs Accessibility).
    @Published var pasteDirectly: Bool {
        didSet { UserDefaults.standard.set(pasteDirectly, forKey: "clipboard.pasteDirectly") }
    }
    /// How the ⌘⇧V overlay looks (chosen in the feature's Options).
    @Published var bezelStyle: BezelStyle {
        didSet { UserDefaults.standard.set(bezelStyle.rawValue, forKey: "clipboard.bezelStyle") }
    }

    static let historyLimitOptions = [10, 25, 50, 100]

    private var timer: Timer?
    private var lastChangeCount = 0

    private override init() {
        let defaults = UserDefaults.standard
        let storedLimit = defaults.integer(forKey: "clipboard.historyLimit")
        historyLimit = Self.historyLimitOptions.contains(storedLimit) ? storedLimit : 25
        rememberAcrossLaunches = defaults.object(forKey: "clipboard.remember") as? Bool ?? true
        pasteDirectly = defaults.bool(forKey: "clipboard.pasteDirectly")
        bezelStyle = BezelStyle(rawValue: defaults.string(forKey: "clipboard.bezelStyle") ?? "") ?? .refined
        super.init()
    }

    // MARK: - FeatureModule

    func activate() {
        if rememberAcrossLaunches {
            clippings = Self.loadHistory()
        }
        // Don't re-capture whatever was on the pasteboard before enabling.
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.captureIfChanged()
        }
        timer.tolerance = 0.2
        self.timer = timer
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        ClipboardBezelController.shared.cancel()
        // Memory is released; the on-disk history (if kept) stays for re-enable.
        if !rememberAcrossLaunches { deleteHistoryFile() }
        clippings = []
        imageCache.removeAllObjects()
    }

    func appWillTerminate() {
        timer?.invalidate()
        timer = nil
        if !rememberAcrossLaunches { deleteHistoryFile() }
    }

    // MARK: - Capture

    private func captureIfChanged() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        // Respect password managers and other apps that mark their content.
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skippedTypes) else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let sourceApp = frontmost?.localizedName
        let sourceBundleID = frontmost?.bundleIdentifier

        if var text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if text.count > Self.maxClippingLength {
                text = String(text.prefix(Self.maxClippingLength))
            }
            rememberText(text, app: sourceApp, bundleID: sourceBundleID)
        } else if let pngData = Self.pngData(from: pasteboard) {
            rememberImage(pngData, app: sourceApp, bundleID: sourceBundleID)
        }
    }

    /// Normalize whatever image is on the pasteboard to PNG data.
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func rememberText(_ text: String, app: String?, bundleID: String?) {
        if promoteExisting(hash: text.sha256, app: app, bundleID: bundleID) { return }
        clippings.insert(Clipping(text: text, sourceApp: app, sourceBundleID: bundleID), at: 0)
        trimAndSave()
    }

    private func rememberImage(_ pngData: Data, app: String?, bundleID: String?) {
        guard pngData.count <= Self.maxImageBytes else { return }
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        if promoteExisting(hash: hash, app: app, bundleID: bundleID) { return }

        guard let rep = NSBitmapImageRep(data: pngData) else { return }
        let fileName = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: Self.imagesDirectory, withIntermediateDirectories: true)
            try pngData.write(to: Self.imagesDirectory.appendingPathComponent(fileName), options: .atomic)
        } catch { return }

        let clipping = Clipping(imageFile: fileName,
                                pixelSize: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh),
                                contentHash: hash,
                                sourceApp: app, sourceBundleID: bundleID)
        clippings.insert(clipping, at: 0)
        trimAndSave()
    }

    /// Re-copied content moves to the top instead of duplicating.
    private func promoteExisting(hash: String, app: String?, bundleID: String?) -> Bool {
        guard let index = clippings.firstIndex(where: { $0.contentHash == hash }) else { return false }
        var clipping = clippings.remove(at: index)
        clipping.date = Date()
        clipping.sourceApp = app ?? clipping.sourceApp
        clipping.sourceBundleID = bundleID ?? clipping.sourceBundleID
        clippings.insert(clipping, at: 0)
        save()
        return true
    }

    private func trimAndSave() {
        while clippings.count > historyLimit {
            removeImageFile(of: clippings.removeLast())
        }
        save()
    }

    // MARK: - Images

    static var imagesDirectory: URL {
        AppSupport.directory.appendingPathComponent("clipboard-images", isDirectory: true)
    }

    func image(for clipping: Clipping) -> NSImage? {
        guard let file = clipping.imageFile else { return nil }
        if let cached = imageCache.object(forKey: file as NSString) { return cached }
        guard let image = NSImage(contentsOf: Self.imagesDirectory.appendingPathComponent(file)) else { return nil }
        imageCache.setObject(image, forKey: file as NSString)
        return image
    }

    private func removeImageFile(of clipping: Clipping) {
        guard let file = clipping.imageFile else { return }
        imageCache.removeObject(forKey: file as NSString)
        try? FileManager.default.removeItem(at: Self.imagesDirectory.appendingPathComponent(file))
    }

    // MARK: - Picking

    /// Put a clipping back on the pasteboard (and paste it if enabled).
    func pick(_ clipping: Clipping) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch clipping.kind {
        case .text:
            pasteboard.setString(clipping.text, forType: .string)
        case .image:
            // Offer the raster data AND the stored file (like Finder's copy),
            // so image-aware apps paste the picture while terminals and file
            // targets get a real file path.
            let item = NSPasteboardItem()
            if let file = clipping.imageFile {
                let url = Self.imagesDirectory.appendingPathComponent(file)
                if let png = try? Data(contentsOf: url) {
                    item.setData(png, forType: .png)
                    if let tiff = NSImage(data: png)?.tiffRepresentation {
                        item.setData(tiff, forType: .tiff)
                    }
                }
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString(url.path, forType: .string)
            }
            pasteboard.writeObjects([item])
        }
        lastChangeCount = pasteboard.changeCount
        _ = promoteExisting(hash: clipping.contentHash,
                            app: clipping.sourceApp, bundleID: clipping.sourceBundleID)

        if pasteDirectly && PermissionKind.accessibility.isGranted {
            // Close our panel first so the previous app is frontmost again.
            NotificationCenter.default.post(name: .sweepClosePanel, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                Self.simulatePaste()
            }
        }
    }

    func delete(_ clipping: Clipping) {
        removeImageFile(of: clipping)
        clippings.removeAll { $0.id == clipping.id }
        save()
    }

    func clearHistory() {
        clippings = []
        deleteHistoryFile()
    }

    /// Synthesize ⌘V so the clipping lands straight in the active app.
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Persistence

    private static var historyURL: URL {
        AppSupport.directory.appendingPathComponent("clipboard-history.json")
    }

    private func save() {
        guard rememberAcrossLaunches else { return }
        if let data = try? JSONEncoder().encode(clippings) {
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    private static func loadHistory() -> [Clipping] {
        guard let data = try? Data(contentsOf: historyURL),
              let stored = try? JSONDecoder().decode([Clipping].self, from: data) else { return [] }
        return stored
    }

    private func deleteHistoryFile() {
        try? FileManager.default.removeItem(at: Self.historyURL)
        try? FileManager.default.removeItem(at: Self.imagesDirectory)
        imageCache.removeAllObjects()
    }

    // MARK: - UI

    func makePanelCard() -> AnyView {
        AnyView(ClipboardCard(module: self))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(ClipboardSettingsView(module: self))
    }
}

// MARK: - Panel card

struct ClipboardCard: View {
    @ObservedObject var module: ClipboardModule
    @State private var pickedID: UUID?

    private static let shownClippings = 5

    var body: some View {
        FeatureCard(id: module.id, title: module.name, systemImage: "doc.on.clipboard",
                    detail: module.clippings.isEmpty ? nil : "\(module.clippings.count)") {
            if module.clippings.isEmpty {
                Text("Nothing copied yet. Copy some text or an image and it shows up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(module.clippings.prefix(Self.shownClippings)) { clipping in
                        row(for: clipping)
                    }
                }

                HStack {
                    Text("\(module.clippings.count) remembered")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { module.clearHistory() }
                        .controlSize(.mini)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private func row(for clipping: Clipping) -> some View {
        Button {
            module.pick(clipping)
            pickedID = clipping.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if pickedID == clipping.id { pickedID = nil }
            }
        } label: {
            HStack(spacing: 6) {
                if clipping.kind == .image, let image = module.image(for: clipping) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(clipping.preview)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if pickedID == clipping.id {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
        .help(clipping.kind == .image ? clipping.preview : String(clipping.text.prefix(300)))
    }
}

// MARK: - Feature settings (card style)

struct ClipboardSettingsView: View {
    @ObservedObject var module: ClipboardModule
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var accessibilityGranted = PermissionKind.accessibility.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("History").font(.headline)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ChipPicker(
                            options: ClipboardModule.historyLimitOptions.map { ("\($0)", $0) },
                            selection: $module.historyLimit
                        )
                        Text("How many clippings — text and images — are remembered. The oldest fall off the end.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("\(module.clippings.count) remembered right now")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "Clear History")) { module.clearHistory() }
                                .controlSize(.small)
                                .disabled(module.clippings.isEmpty)
                        }
                    }
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bezel design").font(.headline)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                                  alignment: .leading, spacing: 12) {
                            ForEach(BezelStyle.allCases) { style in
                                styleChip(style)
                            }
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(module.bezelStyle.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "Preview")) {
                                ClipboardBezelController.shared.showOrAdvance()
                            }
                            .controlSize(.small)
                            .disabled(module.clippings.isEmpty)
                            .help(String(localized: "Shows the real bezel with your clippings. Esc closes it."))
                        }
                    }
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcut").font(.headline)
                SettingsCard {
                    SettingsRow(icon: "command",
                                tint: .teal,
                                title: String(localized: "Show the clipboard bezel"),
                                caption: String(localized: "Press it again (or ← →) to go back and forth through your clippings. Let go of the modifier keys to choose one, then ⌘V pastes it. Esc cancels.")) {
                        ShortcutRecorderView(slot: .clipboard)
                    }
                    if hotkeys.shortcut(for: .clipboard) != nil && !hotkeys.isRegistered(.clipboard) {
                        CardDivider()
                        SettingsRow(icon: "exclamationmark.triangle",
                                    tint: .orange,
                                    title: String(localized: "Another app owns this shortcut"),
                                    caption: String(localized: "The combo couldn't be registered — an app like Flycut is probably already using it. Quit that app and try again, or record a different combo.")) {
                            Button(String(localized: "Try Again")) {
                                HotkeyManager.shared.retryFailedRegistrations()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Options").font(.headline)
                SettingsCard {
                    SettingsRow(icon: "internaldrive",
                                tint: .blue,
                                title: String(localized: "Remember history across launches"),
                                caption: String(localized: "Saved locally in Application Support. Turning this off deletes the saved files.")) {
                        Toggle("", isOn: $module.rememberAcrossLaunches)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    CardDivider()
                    SettingsRow(icon: "keyboard",
                                tint: .purple,
                                title: String(localized: "Paste immediately after picking"),
                                caption: String(localized: "Simulates ⌘V for you after choosing a clipping. Needs the Accessibility permission.")) {
                        Toggle("", isOn: $module.pasteDirectly)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    if module.pasteDirectly && !accessibilityGranted {
                        CardDivider()
                        SettingsRow(icon: "lock.shield",
                                    tint: .orange,
                                    title: String(localized: "Accessibility permission needed"),
                                    caption: String(localized: "Until it is granted, picking a clipping only copies it.")) {
                            Button(String(localized: "Open System Settings")) {
                                NSWorkspace.shared.open(PermissionKind.accessibility.settingsDeepLink)
                            }
                            .controlSize(.small)
                        }
                    }
                    CardDivider()
                    SettingsRow(icon: "key.slash",
                                tint: .gray,
                                title: String(localized: "Passwords are never recorded"),
                                caption: String(localized: "Content that password managers mark as concealed or transient is always skipped."))
                }
            }
        }
        .onAppear { accessibilityGranted = PermissionKind.accessibility.isGranted }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = PermissionKind.accessibility.isGranted
        }
    }

    private func styleChip(_ style: BezelStyle) -> some View {
        let selected = module.bezelStyle == style
        return Button {
            module.bezelStyle = style
        } label: {
            VStack(spacing: 6) {
                BezelStylePreview(style: style)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(
                            selected ? Color.accentColor : Color.white.opacity(0.1),
                            lineWidth: selected ? 2 : 1)
                    )
                HStack(spacing: 4) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(style.displayName)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(style.blurb)
    }
}

// MARK: - ClipboardBezel.swift

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
        case .bottomBar: return CGSize(width: 880, height: 230)
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
/// Pressing the shortcut again (or arrows while holding the modifiers) cycles;
/// releasing the modifier keys (or Return) chooses the shown clipping and puts
/// it on the pasteboard — ⌘V then pastes it. Escape cancels. 1–9 jump.
///
/// The panel is a non-activating key panel: it receives the keystrokes while
/// the app you were using stays frontmost, so pasting lands in the right app.
final class ClipboardBezelController: ObservableObject {
    static let shared = ClipboardBezelController()

    @Published private(set) var index = 0

    private var panel: ClipboardBezelPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    private var navigableCount: Int {
        let count = ClipboardModule.shared.clippings.count
        if let limit = ClipboardModule.shared.bezelStyle.navigableLimit {
            return min(count, limit)
        }
        return count
    }

    /// The global shortcut was pressed: show the bezel, or step forward.
    func showOrAdvance() {
        let module = ClipboardModule.shared
        guard module.isEnabled, !module.clippings.isEmpty else { return }
        if isVisible {
            advance(1)
        } else {
            index = 0
            show()
        }
    }

    func advance(_ delta: Int) {
        let count = navigableCount
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }

    func select(_ newIndex: Int) {
        let count = navigableCount
        guard count > 0 else { return }
        index = min(max(newIndex, 0), count - 1)
    }

    /// 1–9: jump straight to that clipping; in the grid style it also commits.
    func handleDigit(_ digit: Int) {
        let target = digit - 1
        guard target < navigableCount else { return }
        select(target)
        if ClipboardModule.shared.bezelStyle == .grid {
            commit()
        }
    }

    /// Choose the shown clipping: copy it (and auto-paste if enabled).
    func commit() {
        guard isVisible else { return }
        let module = ClipboardModule.shared
        let clipping = module.clippings.indices.contains(index) ? module.clippings[index] : nil
        hide()
        if let clipping {
            module.pick(clipping)
        }
    }

    func cancel() {
        hide()
    }

    /// Commit when every modifier of the recorded shortcut has been released
    /// (the Flycut gesture: hold ⌘⇧, tap V to cycle, let go to choose).
    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard isVisible,
              let shortcut = HotkeyManager.shared.shortcut(for: .clipboard) else { return }
        var required: NSEvent.ModifierFlags = []
        if shortcut.carbonModifiers & UInt32(cmdKey) != 0 { required.insert(.command) }
        if shortcut.carbonModifiers & UInt32(optionKey) != 0 { required.insert(.option) }
        if shortcut.carbonModifiers & UInt32(controlKey) != 0 { required.insert(.control) }
        if flags.intersection(required).isEmpty {
            commit()
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
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}

// MARK: - Panel

/// Borderless, non-activating panel that can take keyboard input without
/// stealing focus from the frontmost app.
final class ClipboardBezelPanel: NSPanel {
    private let controller: ClipboardBezelController

    private static let digitKeyCodes: [Int: Int] = [
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
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: ClipboardBezelView(controller: controller,
                                                                 module: .shared))
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let digit = Self.digitKeyCodes[Int(event.keyCode)] {
            controller.handleDigit(digit)
            return
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            controller.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            controller.commit()
        case kVK_LeftArrow, kVK_UpArrow:
            controller.advance(-1)
        case kVK_RightArrow, kVK_DownArrow:
            controller.advance(1)
        case kVK_ANSI_V where event.modifierFlags.contains(.command):
            // The recorded hotkey normally swallows this; cover other combos.
            controller.advance(1)
        default:
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        controller.flagsChanged(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    override func resignKey() {
        super.resignKey()
        // Clicked elsewhere: dismiss without choosing.
        controller.cancel()
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
        .animation(.easeOut(duration: 0.16), value: controller.index)
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
            symbol = "textformat"
            label = String(localized: "\(clipping.text.count) characters")
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
            if let image = module.image(for: clipping) {
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
        case .text:
            if clipping.text.count <= 140 && !clipping.text.contains("\n") {
                Text(clipping.text)
                    .font(compact ? .body.weight(.medium) : .title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(compact ? 10 : 14)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text(clipping.text)
                    .font(.callout)
                    .lineLimit(compact ? 6 : 10)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
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
            if clipping.kind == .image, let image = module.image(for: clipping) {
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
                .id(clipping.id)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
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
            Group {
                if clipping.kind == .image, let image = module.image(for: clipping) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(clipping.text)
                        .font(.title3.weight(.semibold))
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(clipping.id)
            .transition(.opacity)
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
                    .id(clippings[index].id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
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
                .id(clipping.id)
                .transition(.opacity)
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
                    .id(clipping.id)
                    .transition(.opacity)
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
            if item.kind == .image, let image = module.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 16)
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

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(BezelUI.window(count: clippings.count, index: index, size: 5), id: \.self) { i in
                    card(at: i)
                        .onTapGesture { controller.select(i) }
                }
            }
            .frame(maxHeight: .infinity)
            BezelFooter(index: index, count: clippings.count)
        }
        .padding(16)
    }

    private func card(at i: Int) -> some View {
        let item = clippings[i]
        let selected = i == index
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
                if item.kind == .image, let image = module.image(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(item.text)
                        .font(.caption2)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(9)
        .frame(width: 160, height: selected ? 146 : 134)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.12),
                              lineWidth: selected ? 2 : 1)
        )
        .opacity(selected ? 1 : 0.7)
        .offset(y: selected ? -5 : 0)
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
            if clipping.kind == .image, let image = module.image(for: clipping) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 42, height: 28)
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
                    .id(clipping.id)
                    .transition(.opacity)
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
                if item.kind == .image, let image = module.image(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Text(item.text)
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

// MARK: - IslandClipboardPage (from IslandPages.swift)

// MARK: - Clipboard page (unchanged behavior)

struct IslandClipboardPage: View {
    let onCollapse: () -> Void

    @ObservedObject var module = ClipboardModule.shared
    @ObservedObject var hotkeys = HotkeyManager.shared
    @State private var pickedID: UUID?

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

            if module.clippings.isEmpty {
                islandEmptyState(icon: "doc.on.clipboard",
                                 title: String(localized: "Nothing copied yet"),
                                 caption: String(localized: "Everything you copy appears here."))
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
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(_ clipping: Clipping) -> some View {
        if clipping.kind == .image, let image = module.image(for: clipping) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
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


// MARK: - islandEmptyState (used by IslandClipboardPage, from IslandPages.swift)

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

