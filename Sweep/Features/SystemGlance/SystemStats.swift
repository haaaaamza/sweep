import Foundation
import Darwin

/// Point-in-time system readings (FR-6.1). All local, all cheap.
struct SystemStats {
    var cpuPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64
    var diskFreeBytes: Int64?
    var diskTotalBytes: Int64?
}

/// Samples CPU/memory/disk. CPU is a delta between consecutive samples,
/// so the first reading after (re)start returns nil.
final class SystemStatsSampler {
    private var previousCPUTicks: host_cpu_load_info_data_t?

    func reset() {
        previousCPUTicks = nil
    }

    func sample() -> SystemStats {
        let disk = Self.disk()
        return SystemStats(
            cpuPercent: sampleCPU(),
            memoryUsedBytes: Self.memoryUsed(),
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            diskFreeBytes: disk.free,
            diskTotalBytes: disk.total
        )
    }

    // MARK: - CPU

    private func sampleCPU() -> Double? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previousCPUTicks = info }
        guard let previous = previousCPUTicks else { return nil }

        // cpu_ticks tuple: (user, system, idle, nice)
        let user = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)

        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return busy / total * 100
    }

    // MARK: - Memory

    private static func memoryUsed() -> UInt64? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        let used = (UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)) * UInt64(pageSize)
        return used
    }

    // MARK: - Disk

    private static func disk() -> (free: Int64?, total: Int64?) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage,
                values?.volumeTotalCapacity.map(Int64.init))
    }
}
