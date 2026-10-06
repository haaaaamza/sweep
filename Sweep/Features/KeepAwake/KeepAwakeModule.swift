import SwiftUI
import IOKit.pwr_mgt
import IOKit.ps

/// FR-5: prevent the Mac from sleeping via an IOKit power assertion.
/// No helper tools, no permissions. The assertion dies with the process,
/// so a session can never outlive the app (FR-5.5).
final class KeepAwakeModule: ObservableObject, FeatureModule {
    static let shared = KeepAwakeModule()

    let id = "keep-awake"
    let name = String(localized: "Keep Awake")
    let summary = String(localized: "Stop your Mac from going to sleep, for a while or indefinitely.")
    let requiredPermissions: [PermissionKind] = []

    enum Duration: Int, CaseIterable, Identifiable {
        case indefinite = 0
        case fifteenMinutes = 15
        case thirtyMinutes = 30
        case oneHour = 60
        case twoHours = 120

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .indefinite: return String(localized: "Indefinite")
            case .fifteenMinutes: return String(localized: "15 minutes")
            case .thirtyMinutes: return String(localized: "30 minutes")
            case .oneHour: return String(localized: "1 hour")
            case .twoHours: return String(localized: "2 hours")
            }
        }
    }

    // MARK: - Session state

    @Published private(set) var isSessionActive = false
    @Published private(set) var remaining: TimeInterval?

    // MARK: - Options (persisted)

    @Published var selectedDuration: Duration {
        didSet { UserDefaults.standard.set(selectedDuration.rawValue, forKey: "keepAwake.duration") }
    }
    /// FR-5.3: keep the Mac awake but let the display sleep.
    @Published var allowDisplaySleep: Bool {
        didSet {
            UserDefaults.standard.set(allowDisplaySleep, forKey: "keepAwake.allowDisplaySleep")
            if isSessionActive { recreateAssertion() }
        }
    }
    /// FR-5.4: auto-disable when the battery drops below the threshold.
    @Published var batteryCutoffEnabled: Bool {
        didSet { UserDefaults.standard.set(batteryCutoffEnabled, forKey: "keepAwake.batteryCutoffEnabled") }
    }
    @Published var batteryCutoffPercent: Int {
        didSet { UserDefaults.standard.set(batteryCutoffPercent, forKey: "keepAwake.batteryCutoffPercent") }
    }

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var countdownTimer: Timer?
    private var batteryTimer: Timer?
    private var endDate: Date?

    init() {
        let defaults = UserDefaults.standard
        selectedDuration = Duration(rawValue: defaults.integer(forKey: "keepAwake.duration")) ?? .indefinite
        allowDisplaySleep = defaults.bool(forKey: "keepAwake.allowDisplaySleep")
        batteryCutoffEnabled = defaults.object(forKey: "keepAwake.batteryCutoffEnabled") as? Bool ?? true
        batteryCutoffPercent = defaults.object(forKey: "keepAwake.batteryCutoffPercent") as? Int ?? 10
    }

    func activate() {}

    func deactivate() {
        stopSession()
    }

    // MARK: - Session control

    func startSession() {
        guard !isSessionActive else { return }
        createAssertion()
        guard hasAssertion else { return }
        isSessionActive = true

        if selectedDuration != .indefinite {
            endDate = Date().addingTimeInterval(TimeInterval(selectedDuration.rawValue * 60))
            remaining = endDate?.timeIntervalSinceNow
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tickCountdown()
            }
        } else {
            endDate = nil
            remaining = nil
        }

        if batteryCutoffEnabled {
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.checkBattery()
            }
            checkBattery()
        }
    }

    func stopSession() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        endDate = nil
        remaining = nil
        releaseAssertion()
        isSessionActive = false
    }

    private func tickCountdown() {
        guard let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            stopSession()
        } else {
            remaining = left
        }
    }

    private func checkBattery() {
        guard batteryCutoffEnabled,
              let percent = PowerSource.batteryPercentIfOnBattery(),
              percent < batteryCutoffPercent else { return }
        stopSession()
    }

    // MARK: - IOKit assertion

    private var assertionType: CFString {
        // PreventUserIdleDisplaySleep also keeps the system awake;
        // PreventUserIdleSystemSleep lets the display sleep (FR-5.3).
        (allowDisplaySleep ? "PreventUserIdleSystemSleep" : "PreventUserIdleDisplaySleep") as CFString
    }

    private func createAssertion() {
        guard !hasAssertion else { return }
        let result = IOPMAssertionCreateWithName(
            assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sweep — Keep Awake" as CFString,
            &assertionID
        )
        hasAssertion = (result == kIOReturnSuccess)
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        hasAssertion = false
        assertionID = 0
    }

    private func recreateAssertion() {
        releaseAssertion()
        createAssertion()
    }

    // MARK: - UI

    func makePanelCard() -> AnyView {
        AnyView(KeepAwakeCard(module: self))
    }

    func makeSettingsView() -> AnyView? {
        AnyView(KeepAwakeSettingsView(module: self))
    }
}

/// Battery readout via IOKit power sources.
enum PowerSource {
    /// Battery percentage, but only when actually running on battery power.
    static func batteryPercentIfOnBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let state = description[kIOPSPowerSourceStateKey] as? String,
                  state == kIOPSBatteryPowerValue,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }
}

// MARK: - Panel card

struct KeepAwakeCard: View {
    @ObservedObject var module: KeepAwakeModule

    var body: some View {
        FeatureCard(id: module.id, title: module.name, systemImage: "cup.and.saucer",
                    isActive: module.isSessionActive,
                    detail: statusDetail) {
            Toggle(isOn: sessionBinding) {
                Text("Keep Mac awake")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Picker("For", selection: $module.selectedDuration) {
                ForEach(KeepAwakeModule.Duration.allCases) { duration in
                    Text(duration.label).tag(duration)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .disabled(module.isSessionActive)

            if module.isSessionActive {
                if let remaining = module.remaining {
                    Text("Awake for another \(Self.format(remaining))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Staying awake until you turn this off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Shown in the card header: the countdown, or that it's indefinite.
    private var statusDetail: String? {
        guard module.isSessionActive else { return nil }
        if let remaining = module.remaining { return Self.format(remaining) }
        return String(localized: "Awake")
    }

    private var sessionBinding: Binding<Bool> {
        Binding(
            get: { module.isSessionActive },
            set: { $0 ? module.startSession() : module.stopSession() }
        )
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Feature settings (card style)

struct KeepAwakeSettingsView: View {
    @ObservedObject var module: KeepAwakeModule

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Default duration").font(.headline)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ChipPicker(
                            options: KeepAwakeModule.Duration.allCases.map { ($0.label, $0) },
                            selection: $module.selectedDuration
                        )
                        Text("How long a session runs when you flip the switch in the panel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Options").font(.headline)
                SettingsCard {
                    SettingsRow(icon: "display",
                                tint: .blue,
                                title: String(localized: "Allow the display to sleep"),
                                caption: String(localized: "Keeps the Mac awake while the display follows its normal sleep timer.")) {
                        Toggle("", isOn: $module.allowDisplaySleep)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    CardDivider()
                    SettingsRow(icon: "battery.25percent",
                                tint: .green,
                                title: String(localized: "Stop when battery drops below"),
                                caption: String(localized: "Keeps a forgotten session from draining the battery.")) {
                        HStack(spacing: 10) {
                            Stepper(value: $module.batteryCutoffPercent, in: 5...50, step: 5) {
                                Text("\(module.batteryCutoffPercent)%").monospacedDigit()
                            }
                            .disabled(!module.batteryCutoffEnabled)
                            Toggle("", isOn: $module.batteryCutoffEnabled)
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    CardDivider()
                    SettingsRow(icon: "power",
                                tint: .gray,
                                title: String(localized: "Session ends when Sweep quits"),
                                caption: String(localized: "The sleep assertion can never outlive the app."))
                }
            }
        }
    }
}
