import SwiftUI
import AppKit

/// A minimal shortcut recorder (FR-1.4): click, press a combo, done.
/// Escape cancels recording; Clear removes the shortcut.
struct ShortcutRecorderView: View {
    var slot: HotkeyManager.Slot = .sweepAll

    @State private var isRecording = false
    @State private var shortcut: Shortcut?
    @State private var monitor: Any?

    init(slot: HotkeyManager.Slot = .sweepAll) {
        self.slot = slot
        _shortcut = State(initialValue: HotkeyManager.shared.shortcut(for: slot))
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(buttonTitle)
                    .frame(minWidth: 130)
            }
            .buttonStyle(.bordered)

            if shortcut != nil && !isRecording {
                Button("Clear") {
                    HotkeyManager.shared.setShortcut(nil, for: slot)
                    shortcut = nil
                }
                .buttonStyle(.borderless)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording { return String(localized: "Type shortcut…") }
        return shortcut?.display ?? String(localized: "Record Shortcut")
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                stopRecording() // Escape cancels
                return nil
            }
            if let recorded = Shortcut(event: event) {
                HotkeyManager.shared.setShortcut(recorded, for: slot)
                shortcut = recorded
                stopRecording()
                return nil
            }
            return nil // swallow keys without valid modifiers while recording
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
