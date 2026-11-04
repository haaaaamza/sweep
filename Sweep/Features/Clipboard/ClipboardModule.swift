import SwiftUI
import AppKit
import Carbon.HIToolbox
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

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
    /// Folder of the original pasteboard flavors (RTFD, HTML, images, …).
    var pasteArchiveID: String?
    /// PNG previews so the history panel can show pictures inside a rich copy.
    var previewImageFiles: [String]

    init(text: String, sourceApp: String?, sourceBundleID: String?, pasteArchiveID: String? = nil) {
        self.id = UUID()
        self.kind = .text
        self.text = text
        self.imageFile = nil
        self.imagePixelSize = nil
        self.contentHash = text.sha256
        self.date = Date()
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.pasteArchiveID = pasteArchiveID
        self.previewImageFiles = []
    }

    init(imageFile: String, pixelSize: CGSize, contentHash: String,
         sourceApp: String?, sourceBundleID: String?, pasteArchiveID: String? = nil) {
        self.id = UUID()
        self.kind = .image
        self.text = ""
        self.imageFile = imageFile
        self.imagePixelSize = pixelSize
        self.contentHash = contentHash
        self.date = Date()
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.pasteArchiveID = pasteArchiveID
        self.previewImageFiles = []
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
        pasteArchiveID = try container.decodeIfPresent(String.self, forKey: .pasteArchiveID)
        previewImageFiles = try container.decodeIfPresent([String].self, forKey: .previewImageFiles) ?? []
    }

    /// Text with Notes attachment placeholders removed, so the panel isn't blank.
    var visibleText: String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    /// Single-line preview for the panel card and lists.
    var preview: String {
        if kind == .image {
            if let size = imagePixelSize {
                return String(localized: "Image · \(Int(size.width))×\(Int(size.height))")
            }
            return String(localized: "Image")
        }
        let collapsed = visibleText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.isEmpty {
            if pasteArchiveID != nil || !previewImageFiles.isEmpty {
                return String(localized: "Copied with images")
            }
            return String(localized: "Rich clipping")
        }
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
    /// Reading these fulfills a file promise and can cancel a screenshot save.
    private static let filePromiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.NSFilePromiseItemMetaData",
        "NSPromiseContentsPboardType",
    ]
    /// Clippings larger than these are skipped/truncated when stored.
    private static let maxClippingLength = 100_000
    private static let maxImageBytes = 50_000_000
    /// Caps how many images one Cmd-A copy (e.g. Notes) can add at once.
    private static let maxImagesPerPaste = 12
    private static let flatRTFDType = NSPasteboard.PasteboardType("com.apple.flat-rtfd")
    private static let itemImageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.jpg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.gif"),
        NSPasteboard.PasteboardType("public.webp"),
    ]

    // MARK: - State

    @Published private(set) var clippings: [Clipping] = []

    /// Full-resolution images (paste / rare large previews). Keep this small.
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()
    /// Downsampled previews for the bezel and lists — avoids decoding 5K PNGs in SwiftUI.
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

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
    /// While on, macOS screenshot shortcuts copy instead of writing Desktop files.
    @Published var screenshotsToClipboardOnly: Bool {
        didSet {
            guard ready else { return }
            UserDefaults.standard.set(screenshotsToClipboardOnly, forKey: Self.screenshotsOnlyKey)
            reconcileScreenshotMode()
        }
    }
    /// True when Cmd-Shift-5 Options overrode Sweep's clipboard target.
    @Published private(set) var screenshotModeOverridden = false
    /// Last folder chosen in Save… for image clippings.
    @Published var lastSaveDirectory: URL? {
        didSet {
            guard ready else { return }
            if let lastSaveDirectory {
                UserDefaults.standard.set(lastSaveDirectory.path, forKey: Self.lastSaveFolderKey)
            }
        }
    }

    static let historyLimitOptions = [10, 25, 50, 100]

    private static let screenshotsOnlyKey = "clipboard.screenshotsToClipboardOnly"
    private static let modeActiveKey = "clipboard.screenshotModeActive"
    private static let previousTargetKey = "clipboard.previousScreenshotTarget"
    private static let previousScreenshotTargetKey = "clipboard.previousScreenshotTargetKey"
    private static let previousLocationKey = "clipboard.previousScreenshotLocation"
    private static let lastSaveFolderKey = "clipboard.lastSaveFolder"
    private static let screencaptureDomain = "com.apple.screencapture"

    private var timer: Timer?
    private var lastChangeCount = 0
    /// Gates didSets until crash-safe restore has run.
    private var ready = false
    /// While the ⌘⇧V bezel is up, skip pasteboard polling so @Published
    /// churn doesn't make arrow navigation glitch.
    private var suspendPolling = false
    /// Screenshot thumbnails publish file promises before the image exists.
    /// Reading those types cancels the save, so we wait them out.
    private var pendingPasteboardChange = 0
    private var pendingPasteboardSince: Date?

    func setBezelPollingSuspended(_ suspended: Bool) {
        suspendPolling = suspended
    }

    private override init() {
        let defaults = UserDefaults.standard
        let storedLimit = defaults.integer(forKey: "clipboard.historyLimit")
        historyLimit = Self.historyLimitOptions.contains(storedLimit) ? storedLimit : 25
        rememberAcrossLaunches = defaults.object(forKey: "clipboard.remember") as? Bool ?? true
        pasteDirectly = defaults.bool(forKey: "clipboard.pasteDirectly")
        bezelStyle = BezelStyle(rawValue: defaults.string(forKey: "clipboard.bezelStyle") ?? "") ?? .refined
        screenshotsToClipboardOnly = defaults.bool(forKey: Self.screenshotsOnlyKey)
        if let path = defaults.string(forKey: Self.lastSaveFolderKey) {
            lastSaveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        super.init()
        // Crash-safe: only unwind prefs if the toggle is off but the flag was
        // left set. If the toggle is still on, leave the system as-is — relaunch
        // must not kill Control Center (that makes the menu bar jump).
        if defaults.bool(forKey: Self.modeActiveKey), !screenshotsToClipboardOnly {
            restoreScreenshotDefaults(reloadUIServer: false)
        }
        ready = true
    }

    // MARK: - FeatureModule

    func activate() {
        if rememberAcrossLaunches {
            clippings = Self.loadHistory()
        }
        // Don't re-capture whatever was on the pasteboard before enabling.
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.2
        self.timer = timer
        reconcileScreenshotMode()
        backfillPreviewImages()
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        ClipboardBezelController.shared.cancel()
        releaseScreenshotMode()
        // Memory is released; the on-disk history (if kept) stays for re-enable.
        if !rememberAcrossLaunches { deleteHistoryFile() }
        clippings = []
        imageCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
    }

    func appWillTerminate() {
        timer?.invalidate()
        timer = nil
        releaseScreenshotMode()
        if !rememberAcrossLaunches { deleteHistoryFile() }
    }

    private func tick() {
        if suspendPolling, !ClipboardBezelController.shared.isVisible {
            suspendPolling = false
        }
        guard !suspendPolling else { return }
        captureIfChanged()
        if screenshotsToClipboardOnly {
            enforceScreenshotTarget()
        }
    }

    // MARK: - Capture

    private func captureIfChanged() {
        let pasteboard = NSPasteboard.general
        let change = pasteboard.changeCount
        guard change != lastChangeCount else { return }

        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skippedTypes) else {
            lastChangeCount = change
            pendingPasteboardSince = nil
            return
        }

        if types.contains(where: Self.isFilePromise) || Self.screenshotImageStillPending(pasteboard, types: types) {
            if pendingPasteboardChange != change {
                pendingPasteboardChange = change
                pendingPasteboardSince = Date()
            }
            if let pendingPasteboardSince, Date().timeIntervalSince(pendingPasteboardSince) < 1.2 {
                return
            }
        }
        pendingPasteboardSince = nil
        pendingPasteboardChange = 0
        lastChangeCount = change

        let frontmost = NSWorkspace.shared.frontmostApplication
        ingestPasteboard(pasteboard,
                         app: frontmost?.localizedName,
                         bundleID: frontmost?.bundleIdentifier,
                         includeText: true)
    }

    /// Text is recorded immediately, together with a byte-for-byte copy of the
    /// pasteboard. ⌘⇧V writes that copy back, so Notes gets text and images
    /// the same way a direct ⌘V does.
    private func ingestPasteboard(_ pasteboard: NSPasteboard,
                                  app: String?,
                                  bundleID: String?,
                                  includeText: Bool) {
        let archiveID = Self.savePasteArchive(pasteboard)
        let typeNames = Set((pasteboard.types ?? []).map(\.rawValue))

        // A screenshot is png/tiff plus maybe a filename. Store the picture.
        // Notes articles are rich text and stay on the path below.
        if !Self.hasRichDocument(typeNames), let png = Self.firstAdvertisedImageData(pasteboard) {
            if let file = rememberImage(png, app: app, bundleID: bundleID, archiveID: archiveID) {
                enrichLivePasteboardWithImagePath(imageFile: file)
            }
            return
        }

        if includeText,
           var text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if text.count > Self.maxClippingLength {
                text = String(text.prefix(Self.maxClippingLength))
            }
            rememberText(text, app: app, bundleID: bundleID, archiveID: archiveID)
            schedulePreviewImages(archiveID: archiveID, clippingID: clippings.first?.id)
            return
        }

        if let png = Self.firstAdvertisedImageData(pasteboard) {
            if let file = rememberImage(png, app: app, bundleID: bundleID, archiveID: archiveID) {
                enrichLivePasteboardWithImagePath(imageFile: file)
            }
            return
        }

        if archiveID != nil {
            rememberText(String(localized: "Rich clipping"), app: app, bundleID: bundleID, archiveID: archiveID)
            schedulePreviewImages(archiveID: archiveID, clippingID: clippings.first?.id)
        }
    }

    private static func isFilePromise(_ raw: String) -> Bool {
        if filePromiseTypes.contains(raw) { return true }
        return raw.lowercased().contains("promise")
    }

    private static func hasRichDocument(_ types: Set<String>) -> Bool {
        types.contains(NSPasteboard.PasteboardType.rtfd.rawValue)
            || types.contains(flatRTFDType.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue)
            || types.contains(appleHTMLType.rawValue)
            || types.contains(webArchiveType.rawValue)
    }

    /// png/tiff is listed but the bytes are not ready yet (screenshot still writing).
    private static func screenshotImageStillPending(_ pasteboard: NSPasteboard, types: Set<String>) -> Bool {
        guard !hasRichDocument(types) else { return false }
        let advertised = itemImageTypes.contains { types.contains($0.rawValue) }
        guard advertised else { return false }
        return firstAdvertisedImageData(pasteboard) == nil
    }

    private struct FlavorRecord: Codable {
        var type: String
        var file: String
    }

    private struct ItemRecord: Codable {
        var flavors: [FlavorRecord]
    }

    /// Persist every flavor already on the pasteboard. Does not ask for types
    /// the source app didn't provide, and does not unpack RTFD (that crashed).
    private static func savePasteArchive(_ pasteboard: NSPasteboard) -> String? {
        let items = pasteboard.pasteboardItems ?? []
        guard !items.isEmpty else { return nil }

        let id = UUID().uuidString
        let dir = pasteArchivesDirectory.appendingPathComponent(id, isDirectory: true)
        var records: [ItemRecord] = []
        var total = 0
        var fileIndex = 0

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for item in items {
                var flavors: [FlavorRecord] = []
                for type in item.types {
                    if skippedTypes.contains(type.rawValue) || isFilePromise(type.rawValue) { continue }
                    guard let data = item.data(forType: type), !data.isEmpty else { continue }
                    if data.count > maxImageBytes { continue }
                    total += data.count
                    if total > maxImageBytes { break }
                    let name = "\(fileIndex).bin"
                    fileIndex += 1
                    try data.write(to: dir.appendingPathComponent(name), options: .atomic)
                    flavors.append(FlavorRecord(type: type.rawValue, file: name))
                }
                if !flavors.isEmpty {
                    records.append(ItemRecord(flavors: flavors))
                }
            }
            guard !records.isEmpty else {
                try? FileManager.default.removeItem(at: dir)
                return nil
            }
            try JSONEncoder().encode(records).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            return id
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    private static func firstAdvertisedImageData(_ pasteboard: NSPasteboard) -> Data? {
        let advertised = Set((pasteboard.types ?? []).map(\.rawValue))
        for type in itemImageTypes where advertised.contains(type.rawValue) {
            if let data = pasteboard.data(forType: type), let png = pngData(fromRawImage: data) {
                return png
            }
        }
        return nil
    }

    private static var pasteArchivesDirectory: URL {
        AppSupport.directory.appendingPathComponent("clipboard-pastes", isDirectory: true)
    }

    private func restorePasteArchive(_ id: String) -> Bool {
        let dir = Self.pasteArchivesDirectory.appendingPathComponent(id, isDirectory: true)
        guard let manifest = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let records = try? JSONDecoder().decode([ItemRecord].self, from: manifest),
              !records.isEmpty else { return false }

        var items: [NSPasteboardItem] = []
        for record in records {
            let item = NSPasteboardItem()
            var wrote = false
            for flavor in record.flavors {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(flavor.file)),
                      !data.isEmpty else { continue }
                item.setData(data, forType: NSPasteboard.PasteboardType(flavor.type))
                wrote = true
            }
            if wrote { items.append(item) }
        }
        guard !items.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }

    private func discardPasteArchive(_ id: String?) {
        guard let id else { return }
        try? FileManager.default.removeItem(at: Self.pasteArchivesDirectory.appendingPathComponent(id, isDirectory: true))
    }

    private enum ImagePayloadKind {
        case image
        case rtfd
        case html
        case webArchive
    }

    private struct ImagePayload {
        var kind: ImagePayloadKind
        var data: Data
    }

    /// Copy only representations the pasteboard already advertises.
    /// Asking for missing types blocks on apps like Notes and freezes capture.
    private static func snapshotImagePayloads(_ pasteboard: NSPasteboard) -> [ImagePayload] {
        let advertised = Set((pasteboard.types ?? []).map(\.rawValue))
        var payloads: [ImagePayload] = []

        func take(_ type: NSPasteboard.PasteboardType, kind: ImagePayloadKind, from item: NSPasteboardItem? = nil) {
            guard advertised.contains(type.rawValue) || item?.types.contains(type) == true else { return }
            let data = item?.data(forType: type) ?? pasteboard.data(forType: type)
            guard let data, !data.isEmpty, data.count <= maxImageBytes else { return }
            payloads.append(ImagePayload(kind: kind, data: data))
        }

        for type in itemImageTypes {
            take(type, kind: .image)
        }
        take(.rtfd, kind: .rtfd)
        take(flatRTFDType, kind: .rtfd)
        take(.html, kind: .html)
        take(appleHTMLType, kind: .html)
        take(webArchiveType, kind: .webArchive)

        for item in pasteboard.pasteboardItems ?? [] {
            let itemTypes = Set(item.types.map(\.rawValue))
            for type in itemImageTypes where itemTypes.contains(type.rawValue) {
                take(type, kind: .image, from: item)
            }
            if itemTypes.contains(NSPasteboard.PasteboardType.rtfd.rawValue) {
                take(.rtfd, kind: .rtfd, from: item)
            }
            if itemTypes.contains(flatRTFDType.rawValue) {
                take(flatRTFDType, kind: .rtfd, from: item)
            }
        }
        return payloads
    }

    private static func pngs(from payload: ImagePayload) -> [Data] {
        switch payload.kind {
        case .image:
            return pngData(fromRawImage: payload.data).map { [$0] } ?? []
        case .rtfd:
            return imagesFromRTFDData(payload.data)
        case .html:
            guard let html = String(data: payload.data, encoding: .utf8)
                    ?? String(data: payload.data, encoding: .utf16)
                    ?? String(data: payload.data, encoding: .isoLatin1) else { return [] }
            return imagesReferenced(byHTML: html)
        case .webArchive:
            return imagesFromWebArchiveData(payload.data)
        }
    }

    /// Normalize whatever image is on the pasteboard to PNG data.
    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        for type in itemImageTypes {
            if let data = pasteboard.data(forType: type),
               let png = pngData(fromRawImage: data) {
                return png
            }
        }
        return nil
    }

    private static func pngData(from item: NSPasteboardItem) -> Data? {
        for type in itemImageTypes {
            if let data = item.data(forType: type),
               let png = pngData(fromRawImage: data) {
                return png
            }
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func pngData(contentsOf url: URL) -> Data? {
        let path = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard FileManager.default.fileExists(atPath: path.path),
              let image = NSImage(contentsOf: path) else { return nil }
        return pngData(from: image)
    }

    /// Unpack flat RTFD: attributed attachments AND the serialized FileWrapper tree
    /// (Notes embeds pictures as sibling files next to TXT.rtf).
    private static func imagesFromRTFDData(_ data: Data) -> [Data] {
        var images: [Data] = []

        if let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        ) {
            images.append(contentsOf: imagesFromAttachments(in: attributed))
        } else if let attributed = NSAttributedString(rtfd: data, documentAttributes: nil) {
            images.append(contentsOf: imagesFromAttachments(in: attributed))
        }

        if let package = try? FileWrapper(serializedRepresentation: data) {
            images.append(contentsOf: imagesFromFileWrapper(package))
        }
        return images
    }

    private static func imagesFromAttachments(in attributed: NSAttributedString) -> [Data] {
        var images: [Data] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.attachment, in: full) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let wrapper = attachment.fileWrapper {
                images.append(contentsOf: imagesFromFileWrapper(wrapper))
            }
            if let image = attachment.image, let png = pngData(from: image) {
                images.append(png)
            }
        }
        return images
    }

    private static func imagesFromFileWrapper(_ wrapper: FileWrapper) -> [Data] {
        var images: [Data] = []
        let name = (wrapper.filename ?? wrapper.preferredFilename ?? "").lowercased()

        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            // Skip the RTF body; keep image payloads (png/jpeg/heic/…).
            if !name.hasSuffix(".rtf"), let png = pngData(fromRawImage: data) {
                images.append(png)
            }
        }
        // fileWrappers raises if this wrapper is a file, not a directory.
        if wrapper.isDirectory, let children = wrapper.fileWrappers {
            for (_, child) in children {
                images.append(contentsOf: imagesFromFileWrapper(child))
            }
        }
        return images
    }

    private static let webArchiveType = NSPasteboard.PasteboardType("com.apple.webarchive")
    private static let appleHTMLType = NSPasteboard.PasteboardType("Apple HTML pasteboard type")

    private static func imagesReferenced(byHTML html: String) -> [Data] {
        var images: [Data] = []
        if let dataRegex = try? NSRegularExpression(
            pattern: #"data:image\/[a-zA-Z0-9.+-]+;base64,([A-Za-z0-9+\/=\r\n]+)"#
        ) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            dataRegex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match,
                      let r = Range(match.range(at: 1), in: html),
                      let raw = Data(base64Encoded: String(html[r]).filter { !$0.isWhitespace }),
                      let png = pngData(fromRawImage: raw) else { return }
                images.append(png)
            }
        }
        if let srcRegex = try? NSRegularExpression(
            pattern: #"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            srcRegex.enumerateMatches(in: html, range: range) { match, _, _ in
                guard let match, let r = Range(match.range(at: 1), in: html) else { return }
                let src = String(html[r])
                guard !src.hasPrefix("data:") else { return }
                let url: URL?
                if src.hasPrefix("file:") {
                    url = URL(string: src)
                } else if src.hasPrefix("/") {
                    url = URL(fileURLWithPath: src)
                } else {
                    url = nil
                }
                if let url, let png = pngData(contentsOf: url) {
                    images.append(png)
                }
            }
        }
        return images
    }

    private static func imagesFromWebArchiveData(_ data: Data) -> [Data] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return [] }

        var images: [Data] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let mime = dict["WebResourceMIMEType"] as? String,
                   mime.lowercased().hasPrefix("image/"),
                   let blob = dict["WebResourceData"] as? Data,
                   let png = pngData(fromRawImage: blob) {
                    images.append(png)
                }
                if let html = dict["WebResourceData"] as? Data,
                   let mime = dict["WebResourceMIMEType"] as? String,
                   mime.lowercased().contains("html"),
                   let text = String(data: html, encoding: .utf8) {
                    images.append(contentsOf: imagesReferenced(byHTML: text))
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(plist)
        return images
    }

    private static func pngData(fromRawImage data: Data) -> Data? {
        // Prefer NSImage so HEIC / JPEG / PNG from Notes all convert cleanly.
        if let image = NSImage(data: data), let png = pngData(from: image) {
            return png
        }
        if let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }

    private func rememberText(_ text: String, app: String?, bundleID: String?, archiveID: String? = nil) {
        if promoteExisting(hash: text.sha256, app: app, bundleID: bundleID) {
            attachArchive(archiveID)
            return
        }
        clippings.insert(Clipping(text: text, sourceApp: app, sourceBundleID: bundleID, pasteArchiveID: archiveID), at: 0)
        trimAndSave()
    }

    /// Returns the stored PNG file name of the resulting newest clipping, or
    /// nil if nothing was stored (too large / undecodable).
    @discardableResult
    private func rememberImage(_ pngData: Data, app: String?, bundleID: String?, archiveID: String? = nil) -> String? {
        guard pngData.count <= Self.maxImageBytes else { return nil }
        let hash = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
        if promoteExisting(hash: hash, app: app, bundleID: bundleID) {
            attachArchive(archiveID)
            return clippings.first?.imageFile
        }

        let pixelSize: CGSize
        if let rep = NSBitmapImageRep(data: pngData) {
            pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else if let image = NSImage(data: pngData) {
            pixelSize = image.size
        } else {
            return nil
        }

        let fileName = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: Self.imagesDirectory, withIntermediateDirectories: true)
            try pngData.write(to: Self.imagesDirectory.appendingPathComponent(fileName), options: .atomic)
        } catch { return nil }

        let clipping = Clipping(imageFile: fileName,
                                pixelSize: pixelSize,
                                contentHash: hash,
                                sourceApp: app, sourceBundleID: bundleID,
                                pasteArchiveID: archiveID)
        clippings.insert(clipping, at: 0)
        trimAndSave()
        return fileName
    }

    /// Point the newest clipping at this paste archive, dropping the previous one.
    private func schedulePreviewImages(archiveID: String?, clippingID: UUID?) {
        guard let archiveID, let clippingID else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pngs = Self.previewPNGs(fromArchive: archiveID)
            guard !pngs.isEmpty, let self else { return }
            var files: [String] = []
            for png in pngs.prefix(3) {
                let name = "\(UUID().uuidString).png"
                let url = Self.imagesDirectory.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: Self.imagesDirectory, withIntermediateDirectories: true)
                    try png.write(to: url, options: .atomic)
                    files.append(name)
                } catch { continue }
            }
            guard !files.isEmpty else { return }
            DispatchQueue.main.async {
                guard let index = self.clippings.firstIndex(where: { $0.id == clippingID }) else {
                    files.forEach { try? FileManager.default.removeItem(at: Self.imagesDirectory.appendingPathComponent($0)) }
                    return
                }
                let previous = self.clippings[index].previewImageFiles
                self.clippings[index].previewImageFiles = files
                for file in previous where !files.contains(file) {
                    try? FileManager.default.removeItem(at: Self.imagesDirectory.appendingPathComponent(file))
                }
                self.save()
            }
        }
    }

    /// Older Notes copies were saved before their pictures could be shown.
    private func backfillPreviewImages() {
        let pending = clippings.filter {
            $0.kind == .text && $0.previewImageFiles.isEmpty && $0.pasteArchiveID != nil
        }.prefix(6)
        for clipping in pending {
            schedulePreviewImages(archiveID: clipping.pasteArchiveID, clippingID: clipping.id)
        }
    }

    /// Pull display images out of a saved paste archive without touching FileWrapper directories.
    private static func previewPNGs(fromArchive id: String) -> [Data] {
        let dir = pasteArchivesDirectory.appendingPathComponent(id, isDirectory: true)
        guard let manifest = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let records = try? JSONDecoder().decode([ItemRecord].self, from: manifest) else { return [] }

        var images: [Data] = []
        var seen = Set<String>()
        func add(_ data: Data?) {
            guard let data, images.count < 3 else { return }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(hash).inserted else { return }
            images.append(data)
        }

        for record in records {
            for flavor in record.flavors {
                guard images.count < 3,
                      let data = try? Data(contentsOf: dir.appendingPathComponent(flavor.file)) else { continue }
                let type = flavor.type
                if type == NSPasteboard.PasteboardType.png.rawValue
                    || type == NSPasteboard.PasteboardType.tiff.rawValue
                    || type == "public.jpeg" || type == "public.jpg"
                    || type == "public.heic" || type == "public.gif" || type == "public.webp" {
                    add(pngData(fromRawImage: data))
                } else if type == NSPasteboard.PasteboardType.rtfd.rawValue || type == flatRTFDType.rawValue {
                    for png in imagesFromRTFDData(data).prefix(3) { add(png) }
                } else if type == NSPasteboard.PasteboardType.html.rawValue || type == appleHTMLType.rawValue {
                    if let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
                        for png in imagesReferenced(byHTML: html).prefix(3) { add(png) }
                    }
                } else if type == "com.apple.notes.richtext" {
                    for png in imagesEmbeddedInNotesRichText(data) { add(png) }
                } else if type == webArchiveType.rawValue {
                    for png in imagesFromWebArchiveData(data).prefix(3) { add(png) }
                }
            }
        }
        return images
    }

    /// Notes puts pictures inside `com.apple.notes.richtext` (a keyed archive),
    /// not in public.png. Pull the first content images out in document order
    /// and ignore the small preview that sits next to each full-size picture.
    private static func imagesEmbeddedInNotesRichText(_ data: Data) -> [Data] {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        struct Found {
            var order: Int
            var png: Data
            var aspect: CGFloat
            var area: Int
        }
        var found: [Found] = []
        var search = 0
        while search < data.count,
              let range = data.range(of: signature, in: (data.startIndex + search)..<data.endIndex) {
            let start = data.distance(from: data.startIndex, to: range.lowerBound)
            guard let png = slicePNG(data, start: start), let size = pngPixelSize(png) else {
                search = start + 8
                continue
            }
            search = start + png.count
            guard size.width >= 120, size.height >= 120 else { continue }
            let aspect = size.width / size.height
            let area = Int(size.width * size.height)
            if let match = found.firstIndex(where: { abs($0.aspect - aspect) / max($0.aspect, 0.01) < 0.05 }) {
                if area > found[match].area * 2 {
                    found[match].png = png
                    found[match].aspect = aspect
                    found[match].area = area
                }
            } else {
                found.append(Found(order: found.count, png: png, aspect: aspect, area: area))
            }
        }
        return found.sorted { $0.order < $1.order }.prefix(2).map(\.png)
    }

    private static func slicePNG(_ data: Data, start: Int) -> Data? {
        var cursor = start + 8
        while cursor + 8 <= data.count {
            guard let length = readUInt32BE(data, cursor) else { return nil }
            if length > 20_000_000 { return nil }
            let typeStart = data.startIndex + cursor + 4
            let typeEnd = typeStart + 4
            guard typeEnd <= data.endIndex else { return nil }
            let kind = data[typeStart..<typeEnd]
            let next = cursor + 8 + Int(length) + 4
            if next > data.count { return nil }
            if kind == Data("IEND".utf8) {
                let from = data.startIndex + start
                let to = data.startIndex + next
                return data.subdata(in: from..<to)
            }
            cursor = next
        }
        return nil
    }

    private static func pngPixelSize(_ png: Data) -> CGSize? {
        guard let width = readUInt32BE(png, 16), let height = readUInt32BE(png, 20),
              width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        return (UInt32(data[start]) << 24)
            | (UInt32(data[start + 1]) << 16)
            | (UInt32(data[start + 2]) << 8)
            | UInt32(data[start + 3])
    }

    /// Point the newest clipping at this paste archive, dropping the previous one.
    private func attachArchive(_ archiveID: String?) {
        guard let archiveID, !clippings.isEmpty else { return }
        if clippings[0].pasteArchiveID == archiveID { return }
        discardPasteArchive(clippings[0].pasteArchiveID)
        clippings[0].pasteArchiveID = archiveID
        save()
    }

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
        let cost = Int(image.size.width * image.size.height * 4)
        imageCache.setObject(image, forKey: file as NSString, cost: cost)
        return image
    }

    /// Bezel / list preview — decodes only a small thumbnail via ImageIO.
    func thumbnail(for clipping: Clipping, maxPixel: CGFloat = 360) -> NSImage? {
        let file = clipping.imageFile ?? clipping.previewImageFiles.first
        guard let file else { return nil }
        return thumbnail(file: file, maxPixel: maxPixel)
    }

    func previewThumbnails(for clipping: Clipping, maxPixel: CGFloat = 360) -> [NSImage] {
        clipping.previewImageFiles.compactMap { thumbnail(file: $0, maxPixel: maxPixel) }
    }

    func thumbnail(file: String, maxPixel: CGFloat) -> NSImage? {
        let key = "\(file)@\(Int(maxPixel))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let url = Self.imagesDirectory.appendingPathComponent(file) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let cost = cgImage.bytesPerRow * cgImage.height
        thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    private func removeImageFile(of clipping: Clipping) {
        discardPasteArchive(clipping.pasteArchiveID)
        var files = clipping.previewImageFiles
        if let file = clipping.imageFile { files.append(file) }
        for file in files {
            imageCache.removeObject(forKey: file as NSString)
            for size in [96, 180, 360, 720, 900] as [Int] {
                thumbnailCache.removeObject(forKey: "\(file)@\(size)" as NSString)
            }
            try? FileManager.default.removeItem(at: Self.imagesDirectory.appendingPathComponent(file))
        }
    }

    // MARK: - Picking

    /// Put a clipping back on the pasteboard (and paste it if enabled).
    func pick(_ clipping: Clipping) {
        let pasteboard = NSPasteboard.general
        switch clipping.kind {
        case .text:
            // Rich text/Notes copies restore every original flavor (RTFD, HTML,
            // embedded images, …) from the saved archive when we have one.
            if let archiveID = clipping.pasteArchiveID, restorePasteArchive(archiveID) {
                lastChangeCount = pasteboard.changeCount
            } else {
                pasteboard.clearContents()
                pasteboard.setString(clipping.text, forType: .string)
                lastChangeCount = pasteboard.changeCount
            }
        case .image:
            // Always offer the raster data AND the stored file (like Finder's
            // copy), so image-aware apps paste the picture while terminals and
            // file targets get a real file path. An image's paste archive only
            // holds png/tiff, so restoring it would strip the path — leaving
            // targets like Terminal (which pastes the string flavor) with
            // nothing to paste.
            pasteboard.clearContents()
            if let file = clipping.imageFile {
                pasteboard.writeObjects([Self.imagePasteboardItem(imageFile: file)])
            }
            lastChangeCount = pasteboard.changeCount
        }
        _ = promoteExisting(hash: clipping.contentHash,
                            app: clipping.sourceApp, bundleID: clipping.sourceBundleID)

        if pasteDirectly && PermissionKind.accessibility.isGranted {
            // Close our panel first so the previous app is frontmost again.
            NotificationCenter.default.post(name: .sweepClosePanel, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.simulatePaste()
            }
        }
    }

    /// A pasteboard item for a stored image: the raster data (png/tiff) plus a
    /// real file path (fileURL + string). Image types are written first so
    /// image-aware apps still paste the picture, while terminals and file
    /// targets — which read the string/fileURL — get a usable path.
    private static func imagePasteboardItem(imageFile: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        let url = imagesDirectory.appendingPathComponent(imageFile)
        if let png = try? Data(contentsOf: url) {
            item.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        return item
    }

    /// Right after we capture an image, macOS has left only raster data on the
    /// live pasteboard. Re-publish it with the stored file's path added, so a
    /// direct ⌘V into a terminal or file target works without first opening
    /// history. Keeps our change-count in sync so we don't re-ingest our write.
    private func enrichLivePasteboardWithImagePath(imageFile: String) {
        let url = Self.imagesDirectory.appendingPathComponent(imageFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.imagePasteboardItem(imageFile: imageFile)])
        lastChangeCount = pasteboard.changeCount
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

    // MARK: - Save image clippings

    /// Default Pictures/Screenshots folder (created on demand).
    static var picturesScreenshotsDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Screenshots", isDirectory: true)
    }

    /// Writes the image clipping to `directory` with a timestamped name.
    @discardableResult
    func save(_ clipping: Clipping, toDirectory directory: URL) throws -> URL {
        guard clipping.kind == .image,
              let file = clipping.imageFile else {
            throw ClipboardSaveError.notAnImage
        }
        let source = Self.imagesDirectory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ClipboardSaveError.missingFile
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: clipping.date)
        var name = "Screenshot \(stamp).png"
        var dest = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "Screenshot \(stamp) (\(suffix)).png"
            dest = directory.appendingPathComponent(name)
            suffix += 1
        }
        try FileManager.default.copyItem(at: source, to: dest)
        lastSaveDirectory = directory
        return dest
    }

    func saveToScreenshots(_ clipping: Clipping) throws -> URL {
        try save(clipping, toDirectory: Self.picturesScreenshotsDirectory)
    }

    /// Opens a save panel for an image clipping. Returns the written URL, or nil if cancelled.
    @MainActor
    func saveAs(_ clipping: Clipping) throws -> URL? {
        guard clipping.kind == .image,
              let file = clipping.imageFile else {
            throw ClipboardSaveError.notAnImage
        }
        let source = Self.imagesDirectory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ClipboardSaveError.missingFile
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Screenshot \(clipping.date.formatted(date: .numeric, time: .shortened))"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            + ".png"
        if let lastSaveDirectory {
            panel.directoryURL = lastSaveDirectory
        } else {
            panel.directoryURL = Self.picturesScreenshotsDirectory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: source, to: url)
        lastSaveDirectory = url.deletingLastPathComponent()
        return url
    }

    enum ClipboardSaveError: LocalizedError {
        case notAnImage
        case missingFile

        var errorDescription: String? {
            switch self {
            case .notAnImage: return String(localized: "Only images can be saved as files.")
            case .missingFile: return String(localized: "That clipping’s image file is missing.")
            }
        }
    }

    // MARK: - Screenshots → clipboard mode

    private var isScreenshotModeActive: Bool {
        get { UserDefaults.standard.bool(forKey: Self.modeActiveKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.modeActiveKey) }
    }

    private func reconcileScreenshotMode() {
        if screenshotsToClipboardOnly {
            applyScreenshotClipboardTarget()
        } else {
            releaseScreenshotMode()
        }
    }

    private func releaseScreenshotMode() {
        screenshotModeOverridden = false
        guard isScreenshotModeActive else { return }
        restoreScreenshotDefaults(reloadUIServer: true)
    }

    private func applyScreenshotClipboardTarget() {
        let defaults = UserDefaults.standard
        let current = Self.readScreencaptureDefaults()
        let alreadyClipboard = current.target == "clipboard"
            && current.effectiveScreenshotTarget == "clipboard"

        if !isScreenshotModeActive {
            defaults.set(current.target, forKey: Self.previousTargetKey)
            defaults.set(current.screenshotTarget, forKey: Self.previousScreenshotTargetKey)
            if let location = current.location {
                defaults.set(location, forKey: Self.previousLocationKey)
            } else {
                defaults.removeObject(forKey: Self.previousLocationKey)
            }
        }

        // Skip rewrite + UI reload when prefs are already correct (typical
        // launch path) so the menu bar does not reshuffle.
        if !alreadyClipboard {
            // Recent macOS uses `target-screenshot` for ⌘⇧3/4; older builds used
            // `target`. Set both so Options → Clipboard and shortcuts agree.
            Self.writeScreencapture(target: "clipboard", screenshotTarget: "clipboard", location: nil)
            Self.reloadScreenshotUI()
        }
        isScreenshotModeActive = true
        screenshotModeOverridden = false
    }

    /// Detect when Cmd-Shift-5 Options overrode Sweep; Fix re-asserts.
    private func enforceScreenshotTarget() {
        guard isScreenshotModeActive else { return }
        let current = Self.readScreencaptureDefaults()
        let overridden = current.effectiveScreenshotTarget != "clipboard"
        if screenshotModeOverridden != overridden {
            screenshotModeOverridden = overridden
        }
    }

    /// Re-assert clipboard target after the user overrode it in Screenshot Options.
    func reassertScreenshotClipboardTarget() {
        guard screenshotsToClipboardOnly else { return }
        applyScreenshotClipboardTarget()
    }

    private func restoreScreenshotDefaults(reloadUIServer: Bool) {
        let defaults = UserDefaults.standard
        let target = defaults.string(forKey: Self.previousTargetKey) ?? "file"
        let screenshotTarget = defaults.string(forKey: Self.previousScreenshotTargetKey) ?? target
        let location = defaults.string(forKey: Self.previousLocationKey)
        Self.writeScreencapture(target: target, screenshotTarget: screenshotTarget, location: location)
        if reloadUIServer { Self.reloadScreenshotUI() }
        isScreenshotModeActive = false
        screenshotModeOverridden = false
        defaults.removeObject(forKey: Self.previousTargetKey)
        defaults.removeObject(forKey: Self.previousScreenshotTargetKey)
        defaults.removeObject(forKey: Self.previousLocationKey)
    }

    private static func readScreencaptureDefaults() -> (
        target: String,
        screenshotTarget: String,
        effectiveScreenshotTarget: String,
        location: String?
    ) {
        // Read via `defaults` so we see the same values Screenshot.app writes.
        let target = shellDefaults(read: "target") ?? "file"
        // Sequoia+ uses target-screenshot for ⌘⇧3/4; fall back to target.
        let screenshotTarget = shellDefaults(read: "target-screenshot") ?? target
        let location = shellDefaults(read: "location-screenshot")
            ?? shellDefaults(read: "location")
        return (target, screenshotTarget, screenshotTarget, location)
    }

    private static func shellDefaults(read key: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", screencaptureDomain, key]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private static func writeScreencapture(target: String, screenshotTarget: String, location: String?) {
        // `target` (legacy) + `target-screenshot` (current ⌘⇧3/4 destination).
        shellDefaultsWrite(key: "target", value: target)
        shellDefaultsWrite(key: "target-screenshot", value: screenshotTarget)

        if let prefs = UserDefaults(suiteName: screencaptureDomain) {
            prefs.set(target, forKey: "target")
            prefs.set(screenshotTarget, forKey: "target-screenshot")
            prefs.synchronize()
        }
        CFPreferencesAppSynchronize(screencaptureDomain as CFString)

        if let location, !location.isEmpty {
            shellDefaultsWrite(key: "location", value: location)
            shellDefaultsWrite(key: "location-screenshot", value: location)
            if let prefs = UserDefaults(suiteName: screencaptureDomain) {
                prefs.set(location, forKey: "location")
                prefs.set(location, forKey: "location-screenshot")
                prefs.synchronize()
            }
        }
    }

    private static func shellDefaultsWrite(key: String, value: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", screencaptureDomain, key, value]
        try? process.run()
        process.waitUntilExit()
    }

    private static func reloadScreenshotUI() {
        // Only bounce the screenshot UI helper. Never kill ControlCenter or
        // SystemUIServer — that restarts every menu-bar extra and looks like
        // Wi‑Fi / Clock / battery sliding around on launch.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["screencaptureui"]
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
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
        try? FileManager.default.removeItem(at: Self.pasteArchivesDirectory)
        imageCache.removeAllObjects()
        thumbnailCache.removeAllObjects()
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
                if let image = module.thumbnail(for: clipping, maxPixel: 96) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 18)
                        .clipped()
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
        .contextMenu {
            Button(String(localized: "Copy")) { module.pick(clipping) }
            if clipping.kind == .image {
                Button(String(localized: "Save…")) {
                    _ = try? module.saveAs(clipping)
                }
                Button(String(localized: "Save to Screenshots")) {
                    _ = try? module.saveToScreenshots(clipping)
                }
            }
            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                module.delete(clipping)
            }
        }
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
                Text("Screenshots").font(.headline)
                SettingsCard {
                    SettingsRow(icon: "camera.viewfinder",
                                tint: .teal,
                                title: String(localized: "Screenshots go to clipboard only"),
                                caption: String(localized: "While on, ⌘⇧3 / ⌘⇧4 / ⌘⇧5 copy to the clipboard instead of saving to the Desktop. Right-click a shot in history to save it.")) {
                        Toggle("", isOn: $module.screenshotsToClipboardOnly)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    if module.screenshotsToClipboardOnly && module.screenshotModeOverridden {
                        CardDivider()
                        SettingsRow(icon: "exclamationmark.triangle",
                                    tint: .orange,
                                    title: String(localized: "Screenshot Options changed the destination"),
                                    caption: String(localized: "Cmd-Shift-5 Options overrode Sweep. Tap Fix to send screenshots to the clipboard again.")) {
                            Button(String(localized: "Fix")) {
                                module.reassertScreenshotClipboardTarget()
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
