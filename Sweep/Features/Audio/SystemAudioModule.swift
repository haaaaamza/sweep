import Foundation
import Combine
import CoreAudio
import AppKit

/// Controls the default output device's volume/mute (real, via CoreAudio) and
/// enumerates the apps currently producing audio (macOS 14.4+ process API) for
/// the island's Volume mixer page.
///
/// Note on per-app volume: macOS exposes no public per-application *output*
/// volume. True per-app attenuation requires a CoreAudio process-tap capture +
/// re-render engine (stage 2). This module provides the real master volume and
/// the live list of audio apps; per-app gains are stored and surfaced so the
/// tap engine can apply them once wired.
final class SystemAudioModule: ObservableObject {
    static let shared = SystemAudioModule()

    /// One app currently playing audio.
    struct AudioApp: Identifiable {
        let id: pid_t
        let bundleID: String?
        let name: String
        let icon: NSImage?
        /// Stored UI gain 0...1 (applied by the tap engine once wired).
        var gain: Double
        var muted: Bool
    }

    @Published var masterVolume: Double = 0.5
    @Published var masterMuted: Bool = false
    @Published private(set) var outputDeviceName: String = "Output"
    @Published private(set) var apps: [AudioApp] = []

    private var defaultDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var volumeListenerInstalled = false
    private var gains: [pid_t: Double] = [:]
    private var mutes: [pid_t: Bool] = [:]
    private var refreshTimer: Timer?

    private init() {
        refreshDefaultDevice()
        readMasterVolume()
        readOutputName()
    }

    // MARK: Lifecycle

    func start() {
        refreshDefaultDevice()
        readMasterVolume()
        readOutputName()
        refreshApps()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshApps()
            self?.readMasterVolume()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Master volume

    func setMasterVolume(_ value: Double) {
        let clamped = Float(min(max(value, 0), 1))
        masterVolume = Double(clamped)
        guard defaultDeviceID != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vol = clamped
        if AudioObjectHasProperty(defaultDeviceID, &addr) {
            AudioObjectSetPropertyData(defaultDeviceID, &addr, 0, nil,
                                       UInt32(MemoryLayout<Float>.size), &vol)
        } else {
            // Some devices expose per-channel volume only; set channels 1 & 2.
            for channel: UInt32 in [1, 2] {
                var chAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: channel)
                if AudioObjectHasProperty(defaultDeviceID, &chAddr) {
                    AudioObjectSetPropertyData(defaultDeviceID, &chAddr, 0, nil,
                                               UInt32(MemoryLayout<Float>.size), &vol)
                }
            }
        }
    }

    func toggleMasterMute() {
        setMasterMuted(!masterMuted)
    }

    func setMasterMuted(_ muted: Bool) {
        masterMuted = muted
        guard defaultDeviceID != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(defaultDeviceID, &addr) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(defaultDeviceID, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func readMasterVolume() {
        guard defaultDeviceID != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var vol: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectHasProperty(defaultDeviceID, &addr),
           AudioObjectGetPropertyData(defaultDeviceID, &addr, 0, nil, &size, &vol) == noErr {
            masterVolume = Double(vol)
        }
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muteVal: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(defaultDeviceID, &muteAddr),
           AudioObjectGetPropertyData(defaultDeviceID, &muteAddr, 0, nil, &muteSize, &muteVal) == noErr {
            masterMuted = muteVal != 0
        }
    }

    private func refreshDefaultDevice() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                      &size, &deviceID) == noErr {
            defaultDeviceID = deviceID
        }
    }

    private func readOutputName() {
        guard defaultDeviceID != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(defaultDeviceID, &addr, 0, nil, &size, &name) == noErr,
           let name {
            outputDeviceName = name.takeRetainedValue() as String
        }
    }

    // MARK: Per-app enumeration

    func setGain(_ gain: Double, for id: pid_t) {
        gains[id] = gain
        if let index = apps.firstIndex(where: { $0.id == id }) {
            apps[index].gain = gain
        }
    }

    func toggleMute(for id: pid_t) {
        let newValue = !(mutes[id] ?? false)
        mutes[id] = newValue
        if let index = apps.firstIndex(where: { $0.id == id }) {
            apps[index].muted = newValue
        }
    }

    /// Lists apps producing audio. On macOS 14.4+ this uses the CoreAudio
    /// process-object API; otherwise it falls back to regular running apps that
    /// commonly play audio so the list is never empty.
    private func refreshApps() {
        var result: [AudioApp] = []
        if #available(macOS 14.4, *) {
            for pid in Self.audioProcessPIDs() {
                guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                result.append(AudioApp(id: pid,
                                       bundleID: app.bundleIdentifier,
                                       name: app.localizedName ?? "App",
                                       icon: app.icon,
                                       gain: gains[pid] ?? 1.0,
                                       muted: mutes[pid] ?? false))
            }
        }
        if result.isEmpty {
            // Fallback: foreground GUI apps (best-effort list).
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
            for app in running.prefix(6) {
                let pid = app.processIdentifier
                result.append(AudioApp(id: pid,
                                       bundleID: app.bundleIdentifier,
                                       name: app.localizedName ?? "App",
                                       icon: app.icon,
                                       gain: gains[pid] ?? 1.0,
                                       muted: mutes[pid] ?? false))
            }
        }
        apps = result
    }

    /// PIDs of CoreAudio process objects that are currently running audio.
    @available(macOS 14.4, *)
    private static func audioProcessPIDs() -> [pid_t] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                             &dataSize) == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                         &dataSize, &objectIDs) == noErr else { return [] }

        var pids: [pid_t] = []
        for object in objectIDs {
            // Only include processes actually running audio.
            var runningAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(object, &runningAddr, 0, nil, &runSize, &running) == noErr,
               running == 0 { continue }

            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid) == noErr, pid > 0 {
                pids.append(pid)
            }
        }
        return pids
    }
}
