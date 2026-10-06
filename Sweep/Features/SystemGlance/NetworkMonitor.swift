import Foundation
import Combine

/// Live network throughput sampler. Reads the cumulative byte counters from the
/// active interfaces (via `getifaddrs`) and differentiates them each tick to get
/// upload/download rates — no permissions needed. Drives the System page's
/// Network card and its drill-down line chart.
final class NetworkMonitor: ObservableObject {

    /// One throughput sample: bytes-per-second up and down at a moment in time.
    struct Sample: Identifiable {
        let id = UUID()
        let date: Date
        let downBytesPerSec: Double
        let upBytesPerSec: Double
    }

    /// Instantaneous rates (bytes/sec), nil until the first delta is available.
    @Published private(set) var downloadRate: Double?
    @Published private(set) var uploadRate: Double?
    /// Rolling history for the chart (newest last), capped at `historyLimit`.
    @Published private(set) var history: [Sample] = []
    /// Bytes transferred since this monitor started sampling.
    @Published private(set) var sessionDownBytes: UInt64 = 0
    @Published private(set) var sessionUpBytes: UInt64 = 0

    private let historyLimit = 60
    private var timer: Timer?
    private var lastIn: UInt64?
    private var lastOut: UInt64?
    private var lastSampleDate: Date?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        sampleNow() // prime the counters
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sampleNow() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = false
        lastIn = nil
        lastOut = nil
        lastSampleDate = nil
    }

    private func sampleNow() {
        let (totalIn, totalOut) = Self.interfaceByteCounts()
        let now = Date()
        defer {
            lastIn = totalIn
            lastOut = totalOut
            lastSampleDate = now
        }
        guard let prevIn = lastIn, let prevOut = lastOut, let prevDate = lastSampleDate else { return }
        let elapsed = max(now.timeIntervalSince(prevDate), 0.001)
        // Counters are monotonic but can wrap/reset; clamp negatives to 0.
        let deltaIn = totalIn >= prevIn ? totalIn - prevIn : 0
        let deltaOut = totalOut >= prevOut ? totalOut - prevOut : 0

        let down = Double(deltaIn) / elapsed
        let up = Double(deltaOut) / elapsed
        downloadRate = down
        uploadRate = up
        sessionDownBytes += deltaIn
        sessionUpBytes += deltaOut

        history.append(Sample(date: now, downBytesPerSec: down, upBytesPerSec: up))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    /// Sum of inbound/outbound bytes across all non-loopback interfaces.
    private static func interfaceByteCounts() -> (UInt64, UInt64) {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr else { return (0, 0) }
        defer { freeifaddrs(ifaddrsPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let addr = current.pointee.ifa_addr
            guard let family = addr?.pointee.sa_family, Int32(family) == AF_LINK else { continue }
            let name = String(cString: current.pointee.ifa_name)
            // Skip loopback.
            if name.hasPrefix("lo") { continue }
            guard let data = current.pointee.ifa_data else { continue }
            let networkData = data.assumingMemoryBound(to: if_data.self)
            totalIn += UInt64(networkData.pointee.ifi_ibytes)
            totalOut += UInt64(networkData.pointee.ifi_obytes)
        }
        return (totalIn, totalOut)
    }

    /// "12.4 MB/s" style rate formatting.
    static func formatRate(_ bytesPerSec: Double?) -> String {
        guard let bytesPerSec else { return "Measuring…" }
        return formatBytes(UInt64(max(bytesPerSec, 0))) + "/s"
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(value)) \(units[unit])"
                         : String(format: "%.1f %@", value, units[unit])
    }
}
