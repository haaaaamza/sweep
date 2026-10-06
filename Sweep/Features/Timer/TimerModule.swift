import Foundation
import Combine
import AppKit
import UserNotifications

/// Backs the island's Timer page: a countdown timer, a Pomodoro cycle, and a
/// stopwatch — all self-contained (no permissions beyond optional notifications).
final class TimerModule: ObservableObject {
    static let shared = TimerModule()

    /// Which sub-tool the page is showing.
    enum Mode: String, CaseIterable, Identifiable {
        case timer
        case pomodoro
        case stopwatch
        var id: String { rawValue }
        var label: String {
            switch self {
            case .timer: return String(localized: "Timer")
            case .pomodoro: return String(localized: "Pomodoro")
            case .stopwatch: return String(localized: "Stopwatch")
            }
        }
    }

    /// Pomodoro phase.
    enum PomodoroPhase: String {
        case focus
        case shortBreak
        case longBreak
        var label: String {
            switch self {
            case .focus: return String(localized: "Focus")
            case .shortBreak: return String(localized: "Break")
            case .longBreak: return String(localized: "Long break")
            }
        }
        var minutes: Int {
            switch self {
            case .focus: return 25
            case .shortBreak: return 5
            case .longBreak: return 15
            }
        }
    }

    @Published var mode: Mode = .timer

    // Countdown timer.
    /// Selected duration in minutes (dial value).
    @Published var selectedMinutes: Int = 15
    @Published private(set) var timerRemaining: TimeInterval = 15 * 60
    @Published private(set) var isTimerRunning = false

    // Pomodoro.
    @Published private(set) var pomodoroPhase: PomodoroPhase = .focus
    @Published private(set) var pomodoroRemaining: TimeInterval = TimeInterval(PomodoroPhase.focus.minutes * 60)
    @Published private(set) var isPomodoroRunning = false
    @Published private(set) var completedPomodoros = 0

    // Stopwatch.
    @Published private(set) var stopwatchElapsed: TimeInterval = 0
    @Published private(set) var isStopwatchRunning = false

    private var ticker: Timer?
    private var endDate: Date?
    private var stopwatchStart: Date?
    private var stopwatchBase: TimeInterval = 0

    private init() {}

    /// True if the currently-selected mode has something running.
    var isActive: Bool {
        switch mode {
        case .timer: return isTimerRunning
        case .pomodoro: return isPomodoroRunning
        case .stopwatch: return isStopwatchRunning
        }
    }

    // MARK: Countdown timer

    func setMinutes(_ minutes: Int) {
        guard !isTimerRunning else { return }
        selectedMinutes = max(1, minutes)
        timerRemaining = TimeInterval(selectedMinutes * 60)
    }

    func startTimer() {
        guard !isTimerRunning else { return }
        if timerRemaining <= 0 { timerRemaining = TimeInterval(selectedMinutes * 60) }
        endDate = Date().addingTimeInterval(timerRemaining)
        isTimerRunning = true
        startTicker()
    }

    func stopTimer() {
        isTimerRunning = false
        endDate = nil
        timerRemaining = TimeInterval(selectedMinutes * 60)
        stopTickerIfIdle()
    }

    // MARK: Pomodoro

    func startPomodoro() {
        guard !isPomodoroRunning else { return }
        endDate = Date().addingTimeInterval(pomodoroRemaining)
        isPomodoroRunning = true
        startTicker()
    }

    func stopPomodoro() {
        isPomodoroRunning = false
        endDate = nil
        pomodoroRemaining = TimeInterval(pomodoroPhase.minutes * 60)
        stopTickerIfIdle()
    }

    private func advancePomodoro() {
        if pomodoroPhase == .focus {
            completedPomodoros += 1
            pomodoroPhase = (completedPomodoros % 4 == 0) ? .longBreak : .shortBreak
        } else {
            pomodoroPhase = .focus
        }
        pomodoroRemaining = TimeInterval(pomodoroPhase.minutes * 60)
        endDate = Date().addingTimeInterval(pomodoroRemaining)
    }

    // MARK: Stopwatch

    func startStopwatch() {
        guard !isStopwatchRunning else { return }
        stopwatchStart = Date()
        isStopwatchRunning = true
        startTicker()
    }

    func pauseStopwatch() {
        guard isStopwatchRunning else { return }
        stopwatchBase = stopwatchElapsed
        isStopwatchRunning = false
        stopwatchStart = nil
        stopTickerIfIdle()
    }

    func resetStopwatch() {
        isStopwatchRunning = false
        stopwatchStart = nil
        stopwatchBase = 0
        stopwatchElapsed = 0
        stopTickerIfIdle()
    }

    // MARK: Ticking

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTickerIfIdle() {
        guard !isTimerRunning, !isPomodoroRunning, !isStopwatchRunning else { return }
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let now = Date()
        if isTimerRunning, let end = endDate {
            timerRemaining = max(0, end.timeIntervalSince(now))
            if timerRemaining <= 0 {
                isTimerRunning = false
                endDate = nil
                timerRemaining = TimeInterval(selectedMinutes * 60)
                notify(title: String(localized: "Timer finished"),
                       body: String(localized: "Your \(selectedMinutes)-minute timer is done."))
                stopTickerIfIdle()
            }
        }
        if isPomodoroRunning, let end = endDate {
            pomodoroRemaining = max(0, end.timeIntervalSince(now))
            if pomodoroRemaining <= 0 {
                let finished = pomodoroPhase
                advancePomodoro()
                notify(title: String(localized: "\(finished.label) complete"),
                       body: String(localized: "Starting \(pomodoroPhase.label)."))
            }
        }
        if isStopwatchRunning, let start = stopwatchStart {
            stopwatchElapsed = stopwatchBase + now.timeIntervalSince(start)
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: Formatting

    /// "25:00" or "1:05:00" for a positive interval.
    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// Stopwatch precision: "00:00.0".
    static func formatStopwatch(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let m = (total % 3600) / 60
        let s = total % 60
        let tenths = Int((interval - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }
}
