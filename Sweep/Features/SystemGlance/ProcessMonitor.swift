import AppKit
import Darwin

/// One running app with every helper process it launched folded in,
/// Vitals-style: "every app gets one row and one figure".
struct AppUsageGroup: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processCount: Int
    var memoryBytes: UInt64
    var cpuPercent: Double
    var isSystem: Bool
}

/// Samples all processes via libproc, walks each one's parent chain to the
/// app that owns it, and publishes per-app totals. Runs a 2 s timer only
/// while the Monitor window is open — zero cost otherwise.
final class ProcessMonitor: ObservableObject {
    @Published private(set) var groups: [AppUsageGroup] = []
    @Published private(set) var totals: SystemStats?

    private var timer: Timer?
    private let sampler = SystemStatsSampler()
    private var previousCPUTimeNs: [pid_t: UInt64] = [:]
    private var previousSampleAt: TimeInterval?
    private var isSampling = false

    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func start() {
        guard timer == nil else { return }
        sampler.reset()
        previousCPUTimeNs = [:]
        previousSampleAt = nil
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousCPUTimeNs = [:]
        previousSampleAt = nil
    }

    private func refresh() {
        guard !isSampling else { return }
        isSampling = true

        // Snapshot app identities on the main thread; crunch off it.
        struct AppRef {
            let pid: pid_t
            let bundleID: String
            let name: String
            let icon: NSImage?
        }
        let apps: [AppRef] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return AppRef(pid: app.processIdentifier, bundleID: bundleID,
                          name: app.localizedName ?? bundleID, icon: app.icon)
        }
        let stats = sampler.sample()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.sampleGroups(apps: apps.map { ($0.pid, $0.bundleID, $0.name, $0.icon) })
            DispatchQueue.main.async {
                self.groups = result
                self.totals = stats
                self.isSampling = false
            }
        }
    }

    // MARK: - Sampling

    private func sampleGroups(apps: [(pid: pid_t, bundleID: String, name: String, icon: NSImage?)]) -> [AppUsageGroup] {
        // Terminated apps report pid -1, so several entries can share a pid —
        // Dictionary(uniqueKeysWithValues:) would trap on those duplicates.
        let appByPid = Dictionary(apps.filter { $0.pid > 0 }.map { ($0.pid, $0) },
                                  uniquingKeysWith: { first, _ in first })

        // All pids + parent map.
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        pids.removeSubrange(min(Int(got), pids.count)...)

        var parent: [pid_t: pid_t] = [:]
        var footprint: [pid_t: UInt64] = [:]
        var cpuTimeNs: [pid_t: UInt64] = [:]

        for pid in pids where pid > 0 {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                                    Int32(MemoryLayout<proc_bsdinfo>.size))
            if size == Int32(MemoryLayout<proc_bsdinfo>.size) {
                parent[pid] = pid_t(info.pbi_ppid)
            }

            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result == 0 else { continue }
            footprint[pid] = usage.ri_phys_footprint
            let machTime = usage.ri_user_time &+ usage.ri_system_time
            cpuTimeNs[pid] = machTime &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        }

        // CPU deltas since the previous sample.
        let now = Date.timeIntervalSinceReferenceDate
        let interval = previousSampleAt.map { now - $0 }
        var cpuDeltaNs: [pid_t: UInt64] = [:]
        if interval != nil {
            for (pid, time) in cpuTimeNs {
                if let previous = previousCPUTimeNs[pid], time >= previous {
                    cpuDeltaNs[pid] = time - previous
                }
            }
        }
        previousCPUTimeNs = cpuTimeNs
        previousSampleAt = now

        // Attribute every process to the app that owns it (walk the parent chain).
        func owningApp(of pid: pid_t) -> pid_t? {
            var current: pid_t? = pid
            var depth = 0
            while let p = current, p > 1, depth < 16 {
                if appByPid[p] != nil { return p }
                current = parent[p]
                depth += 1
            }
            return nil
        }

        struct Accumulator {
            var count = 0
            var memory: UInt64 = 0
            var cpuNs: UInt64 = 0
        }
        var byApp: [pid_t: Accumulator] = [:]
        var system = Accumulator()

        for pid in pids where pid > 0 {
            guard footprint[pid] != nil || cpuTimeNs[pid] != nil else {
                // Not readable (root process): still count it for the system group.
                if owningApp(of: pid) == nil { system.count += 1 }
                continue
            }
            if let appPid = owningApp(of: pid) {
                var acc = byApp[appPid] ?? Accumulator()
                acc.count += 1
                acc.memory &+= footprint[pid] ?? 0
                acc.cpuNs &+= cpuDeltaNs[pid] ?? 0
                byApp[appPid] = acc
            } else {
                system.count += 1
                system.memory &+= footprint[pid] ?? 0
                system.cpuNs &+= cpuDeltaNs[pid] ?? 0
            }
        }

        func percent(_ cpuNs: UInt64) -> Double {
            guard let interval, interval > 0 else { return 0 }
            return Double(cpuNs) / (interval * 1_000_000_000) * 100
        }

        var result: [AppUsageGroup] = byApp.compactMap { pid, acc in
            guard let app = appByPid[pid] else { return nil }
            return AppUsageGroup(id: app.bundleID, name: app.name, icon: app.icon,
                                 processCount: acc.count, memoryBytes: acc.memory,
                                 cpuPercent: percent(acc.cpuNs), isSystem: false)
        }
        if system.count > 0 {
            result.append(AppUsageGroup(id: "sweep.system-group", name: "macOS", icon: nil,
                                        processCount: system.count, memoryBytes: system.memory,
                                        cpuPercent: percent(system.cpuNs), isSystem: true))
        }
        return result.sorted { $0.memoryBytes > $1.memoryBytes }
    }
}
