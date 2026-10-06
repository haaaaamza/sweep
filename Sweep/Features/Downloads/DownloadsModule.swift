import Foundation
import Combine
import AppKit

/// Watches a chosen folder (default: ~/Downloads) and surfaces the most recent
/// files for the island's Downloads page. Uses a bookmark so access survives
/// relaunches; the folder is polled via a DispatchSource on its directory.
final class DownloadsModule: ObservableObject {
    static let shared = DownloadsModule()

    struct Item: Identifiable {
        let id: String
        let url: URL
        let name: String
        let size: Int64
        let date: Date
        let icon: NSImage
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "downloads.enabled")
            if isEnabled { startWatching() } else { stopWatching() }
        }
    }
    @Published private(set) var folderURL: URL?
    @Published private(set) var items: [Item] = []

    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private let bookmarkKey = "downloads.folderBookmark"

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "downloads.enabled") as? Bool ?? true
        folderURL = Self.resolveFolder(bookmarkKey: bookmarkKey)
        if isEnabled { startWatching() }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Watch Folder")
        panel.directoryURL = folderURL
        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            }
            folderURL = url
            startWatching()
        }
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: Item) {
        NSWorkspace.shared.open(item.url)
    }

    // MARK: Watching

    private static func resolveFolder(bookmarkKey: String) -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func startWatching() {
        stopWatching()
        guard let folderURL else { return }
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        reloadItems()

        let fd = Darwin.open(folderURL.path, O_EVTONLY)
        guard fd >= 0 else {
            if didAccess { folderURL.stopAccessingSecurityScopedResource() }
            return
        }
        watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.reloadItems() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchedFD, fd >= 0 { close(fd) }
            self?.watchedFD = -1
        }
        source.resume()
        self.source = source
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        folderURL?.stopAccessingSecurityScopedResource()
    }

    private func reloadItems() {
        guard let folderURL else { items = []; return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []

        let mapped: [Item] = contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Skip in-progress downloads and folders.
            if url.pathExtension == "download" || url.pathExtension == "crdownload" { return nil }
            if values?.isDirectory == true { return nil }
            let date = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return Item(id: url.path, url: url, name: url.lastPathComponent,
                        size: size, date: date, icon: icon)
        }
        .sorted { $0.date > $1.date }

        items = Array(mapped.prefix(12))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
