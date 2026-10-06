import Foundation
import Combine

/// Tracks local Claude Code usage by scanning the transcript JSONL files under
/// ~/.claude/projects, summing today's token usage and estimating API-equivalent
/// cost. Drives the island's "AI Agents" page. All reads are local.
final class AIAgentsModule: ObservableObject {
    static let shared = AIAgentsModule()

    struct Usage {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0

        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
        /// Share of input served from cache (cheap).
        var cacheFraction: Double {
            let readable = inputTokens + cacheReadTokens + cacheWriteTokens
            guard readable > 0 else { return 0 }
            return Double(cacheReadTokens) / Double(readable)
        }
    }

    struct RecentAgent: Identifiable {
        let id = UUID()
        let name: String
        let lastActive: Date
    }

    @Published private(set) var today = Usage()
    @Published private(set) var estimatedCost: Double = 0
    /// 24 hourly buckets of API-value cost for today (index 0 = 12 AM).
    @Published private(set) var hourlyCost: [Double] = Array(repeating: 0, count: 24)
    @Published private(set) var recent: [RecentAgent] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var lastActivity: Date?

    private var refreshTimer: Timer?
    private let queue = DispatchQueue(label: "sweep.aiagents", qos: .utility)

    // Rough Claude pricing ($ per million tokens) for an API-value estimate.
    private let inPrice = 3.0, outPrice = 15.0, cacheReadPrice = 0.30, cacheWritePrice = 3.75

    private init() {
        let dir = Self.projectsDirectory
        isAvailable = FileManager.default.fileExists(atPath: dir.path)
    }

    func start() {
        guard isAvailable else { return }
        refresh()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let (usage, hourly, agents, last) = self.scan()
            let cost = Double(usage.inputTokens) / 1_000_000 * self.inPrice
                + Double(usage.outputTokens) / 1_000_000 * self.outPrice
                + Double(usage.cacheReadTokens) / 1_000_000 * self.cacheReadPrice
                + Double(usage.cacheWriteTokens) / 1_000_000 * self.cacheWritePrice
            DispatchQueue.main.async {
                self.today = usage
                self.estimatedCost = cost
                self.hourlyCost = hourly
                self.recent = agents
                self.lastActivity = last
            }
        }
    }

    /// Walk today's transcript files and total their per-message usage.
    private func scan() -> (Usage, [Double], [RecentAgent], Date?) {
        var usage = Usage()
        var hourly = Array(repeating: 0.0, count: 24)
        var lastActivity: Date?
        let calendar = Calendar.current
        let fm = FileManager.default
        let root = Self.projectsDirectory

        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else {
            return (usage, hourly, [], nil)
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, calendar.isDateInToday(modified) else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // Timestamp → keep only today, bucket by hour.
                var eventDate: Date?
                if let ts = obj["timestamp"] as? String {
                    eventDate = ISO8601DateFormatter().date(from: ts)
                }
                if let eventDate, !calendar.isDateInToday(eventDate) { continue }

                guard let message = obj["message"] as? [String: Any],
                      let u = message["usage"] as? [String: Any] else { continue }

                let input = u["input_tokens"] as? Int ?? 0
                let output = u["output_tokens"] as? Int ?? 0
                let cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
                let cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0

                usage.inputTokens += input
                usage.outputTokens += output
                usage.cacheReadTokens += cacheRead
                usage.cacheWriteTokens += cacheWrite

                let lineCost = Double(input) / 1_000_000 * inPrice
                    + Double(output) / 1_000_000 * outPrice
                    + Double(cacheRead) / 1_000_000 * cacheReadPrice
                    + Double(cacheWrite) / 1_000_000 * cacheWritePrice

                if let eventDate {
                    let hour = calendar.component(.hour, from: eventDate)
                    if hour >= 0 && hour < 24 { hourly[hour] += lineCost }
                    if lastActivity == nil || eventDate > lastActivity! { lastActivity = eventDate }
                }
            }
        }

        var agents: [RecentAgent] = []
        if let lastActivity {
            agents.append(RecentAgent(name: "Claude", lastActive: lastActivity))
        }
        return (usage, hourly, agents, lastActivity)
    }

    // MARK: Formatting

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.0fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    static func formatCost(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return String(localized: "just now") }
        if seconds < 3600 { return String(localized: "\(Int(seconds / 60)) min. ago") }
        if seconds < 86400 { return String(localized: "\(Int(seconds / 3600)) hr. ago") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
