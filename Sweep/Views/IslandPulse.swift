import SwiftUI
import AppKit
import IOKit.ps

// MARK: - Pulse model

/// A short Dynamic Island expansion — widen, show a message, then collapse
/// (same idea as iPhone charging / Face ID pulses).
struct IslandPulse: Identifiable, Equatable {
    enum Tint: Equatable {
        case accent, orange, green, yellow, red, white

        var color: Color {
            switch self {
            case .accent: return Color.accentColor
            case .orange: return .orange
            case .green: return .green
            case .yellow: return .yellow
            case .red: return .red
            case .white: return .white
            }
        }
    }

    let id: UUID
    let symbol: String
    let title: String
    let detail: String?
    let tint: Tint
    /// How long the widened island stays before collapsing.
    let duration: TimeInterval

    init(id: UUID = UUID(),
         symbol: String,
         title: String,
         detail: String? = nil,
         tint: Tint = .accent,
         duration: TimeInterval = 2.2) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.tint = tint
        self.duration = duration
    }

    // MARK: Presets

    static var swept: IslandPulse {
        IslandPulse(symbol: "wind.circle.fill",
                    title: String(localized: "Swept"),
                    detail: String(localized: "Desktop & apps"),
                    tint: .orange)
    }

    static var restored: IslandPulse {
        IslandPulse(symbol: "arrow.uturn.backward.circle.fill",
                    title: String(localized: "Restored"),
                    detail: String(localized: "Everything’s back"),
                    tint: .green)
    }

    static func charging(percent: Int?) -> IslandPulse {
        let detail = percent.map { String(localized: "\($0)%") }
        return IslandPulse(symbol: "bolt.fill",
                           title: String(localized: "Charging"),
                           detail: detail,
                           tint: .green)
    }

    static func unplugged(percent: Int?) -> IslandPulse {
        let detail = percent.map { String(localized: "\($0)%") }
        return IslandPulse(symbol: "bolt.slash.fill",
                           title: String(localized: "On battery"),
                           detail: detail,
                           tint: .yellow)
    }

    static func lowBattery(percent: Int) -> IslandPulse {
        IslandPulse(symbol: "battery.25",
                    title: String(localized: "Low battery"),
                    detail: String(localized: "\(percent)%"),
                    tint: .red,
                    duration: 2.8)
    }
}

// MARK: - Power / battery → island pulses

/// Watches AC power and battery level; posts island pulses when they change.
final class SystemPowerMonitor {
    static let shared = SystemPowerMonitor()

    private var runLoopSource: CFRunLoopSource?
    private var onAC: Bool?
    private var lowBatteryWarned = false
    private let lowThreshold = 20

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { monitor.refresh(initial: false) }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        refresh(initial: true)
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    private func refresh(initial: Bool) {
        let snapshot = Self.readPower()
        defer {
            onAC = snapshot.onAC
            if let percent = snapshot.percent, percent > lowThreshold {
                lowBatteryWarned = false
            }
        }
        guard !initial else { return }

        if let previous = onAC, previous != snapshot.onAC {
            if snapshot.onAC {
                DynamicIslandController.shared.presentPulse(.charging(percent: snapshot.percent))
            } else if snapshot.isBattery {
                DynamicIslandController.shared.presentPulse(.unplugged(percent: snapshot.percent))
            }
        }

        if snapshot.isBattery,
           let percent = snapshot.percent,
           percent <= lowThreshold,
           !lowBatteryWarned {
            lowBatteryWarned = true
            DynamicIslandController.shared.presentPulse(.lowBattery(percent: percent))
        }
    }

    private struct Snapshot {
        var onAC: Bool
        var isBattery: Bool
        var percent: Int?
    }

    private static func readPower() -> Snapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            return Snapshot(onAC: true, isBattery: false, percent: nil)
        }

        var onAC = false
        var isBattery = false
        var percent: Int?

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSACPowerValue { onAC = true }
            }
            if let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                isBattery = true
                if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                   let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = Int((Double(cur) / Double(max) * 100).rounded())
                } else if let cur = desc[kIOPSCurrentCapacityKey] as? Int {
                    percent = cur
                }
            }
        }
        return Snapshot(onAC: onAC, isBattery: isBattery, percent: percent)
    }
}
