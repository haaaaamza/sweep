import Foundation
import Combine
import AppKit

/// Reads the system "now playing" track and sends transport commands via the
/// private MediaRemote framework, loaded at runtime with `dlopen` (so the app
/// still builds and runs where the framework is unavailable).
///
/// Apple restricted MediaRemote for third parties around macOS 15.4, so on newer
/// systems `info` stays nil and the UI shows its "Nothing playing" state. The
/// transport calls are no-ops there rather than crashing.
final class NowPlayingModule: ObservableObject {
    static let shared = NowPlayingModule()

    struct TrackInfo: Equatable {
        var title: String
        var artist: String?
        var album: String?
        var artwork: NSImage?
        var isPlaying: Bool
        var duration: TimeInterval?
        var elapsed: TimeInterval?
    }

    @Published private(set) var info: TrackInfo?
    /// True when MediaRemote is available on this OS.
    @Published private(set) var isAvailable = false

    private var pollTimer: Timer?

    // MediaRemote function pointers (resolved once).
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int, [String: Any]?) -> Bool
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void

    private var getInfo: GetInfoFn?
    private var sendCommand: SendCommandFn?
    private var handle: UnsafeMutableRawPointer?

    private init() {
        loadMediaRemote()
    }

    func start() {
        guard isAvailable else { return }
        poll()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Transport

    func togglePlayPause() { send(command: 2) }   // kMRTogglePlayPause
    func nextTrack() { send(command: 4) }         // kMRNextTrack
    func previousTrack() { send(command: 5) }     // kMRPreviousTrack

    private func send(command: Int) {
        _ = sendCommand?(command, nil)
        // Reflect the change quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    // MARK: MediaRemote loading

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else { return }
        self.handle = handle

        guard let infoSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return }
        getInfo = unsafeBitCast(infoSym, to: GetInfoFn.self)

        if let cmdSym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(cmdSym, to: SendCommandFn.self)
        }
        if let regSym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            let register = unsafeBitCast(regSym, to: RegisterFn.self)
            register(DispatchQueue.main)
        }
        isAvailable = getInfo != nil
    }

    private func poll() {
        guard let getInfo else { return }
        getInfo(DispatchQueue.main) { [weak self] raw in
            guard let self else { return }
            self.apply(raw)
        }
    }

    private func apply(_ raw: [String: Any]) {
        let title = raw["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        guard let title, !title.isEmpty else {
            info = nil
            return
        }
        var artwork: NSImage?
        if let data = raw["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
            artwork = NSImage(data: data)
        }
        let rate = raw["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        info = TrackInfo(
            title: title,
            artist: raw["kMRMediaRemoteNowPlayingInfoArtist"] as? String,
            album: raw["kMRMediaRemoteNowPlayingInfoAlbum"] as? String,
            artwork: artwork,
            isPlaying: rate > 0,
            duration: raw["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval,
            elapsed: raw["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval)
    }
}
