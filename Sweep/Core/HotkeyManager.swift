import AppKit
import Carbon.HIToolbox

/// A recorded global shortcut, stored with Carbon key code + modifiers.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // A global shortcut must include at least one real modifier.
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon)
    }

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += Shortcut.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        let special: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        if let name = special[keyCode] { return name }

        // Translate using the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
            let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers system-wide hotkeys via Carbon (no permissions needed) and fires
/// the matching slot's action when one is pressed (FR-1.4 / FR-4.3).
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// One registerable hotkey. `sweepAll` toggles Sweep All; `clipboard`
    /// shows the clipboard history bezel.
    enum Slot: UInt32, CaseIterable {
        case sweepAll = 1
        case clipboard = 2

        var defaultsKey: String {
            switch self {
            case .sweepAll: return "sweep.shortcut"
            case .clipboard: return "clipboard.shortcut"
            }
        }
    }

    /// Fired when the Sweep All hotkey is pressed.
    var action: (() -> Void)?
    /// Fired when the clipboard history hotkey is pressed.
    var clipboardAction: (() -> Void)?

    @Published private var shortcuts: [Slot: Shortcut] = [:]
    /// Slots whose RegisterEventHotKey failed — usually because another app
    /// (e.g. the real Flycut) already owns the same combo.
    @Published private(set) var registrationFailures: Set<Slot> = []

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    /// Set once the user explicitly clears the clipboard shortcut, so the
    /// default ⌘⇧V isn't resurrected on the next launch.
    private let clipboardClearedKey = "clipboard.shortcut.cleared"

    /// The Sweep All shortcut (kept for existing call sites).
    var shortcut: Shortcut? { shortcuts[.sweepAll] }

    func shortcut(for slot: Slot) -> Shortcut? {
        shortcuts[slot]
    }

    func isRegistered(_ slot: Slot) -> Bool {
        shortcuts[slot] != nil && !registrationFailures.contains(slot)
    }

    func start() {
        for slot in Slot.allCases {
            if let data = UserDefaults.standard.data(forKey: slot.defaultsKey),
               let stored = try? JSONDecoder().decode(Shortcut.self, from: data) {
                shortcuts[slot] = stored
            }
        }
        // Flycut's classic ⌘⇧V out of the box, unless explicitly cleared.
        if shortcuts[.clipboard] == nil,
           !UserDefaults.standard.bool(forKey: clipboardClearedKey) {
            shortcuts[.clipboard] = Shortcut(keyCode: UInt32(kVK_ANSI_V),
                                             carbonModifiers: UInt32(cmdKey | shiftKey))
        }
        installHandler()
        for slot in Slot.allCases { register(slot) }
    }

    func setShortcut(_ newShortcut: Shortcut?) {
        setShortcut(newShortcut, for: .sweepAll)
    }

    func setShortcut(_ newShortcut: Shortcut?, for slot: Slot) {
        unregister(slot)
        shortcuts[slot] = newShortcut
        if let newShortcut, let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: slot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: slot.defaultsKey)
        }
        if slot == .clipboard {
            UserDefaults.standard.set(newShortcut == nil, forKey: clipboardClearedKey)
        }
        register(slot)
    }

    /// Re-try failed registrations (e.g. after the user quits the app that
    /// was holding the combo).
    func retryFailedRegistrations() {
        for slot in registrationFailures { register(slot) }
    }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let slot = Slot(rawValue: hotKeyID.id)
            // Always hop to the main queue — Carbon does not guarantee it, and
            // off-main UI made the clipboard bezel miss shows / stick open.
            DispatchQueue.main.async {
                switch slot {
                case .sweepAll: manager.action?()
                case .clipboard: manager.clipboardAction?()
                case nil: break
                }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func register(_ slot: Slot) {
        guard let shortcut = shortcuts[slot] else {
            registrationFailures.remove(slot)
            return
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x53574550) /* 'SWEP' */, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs[slot] = ref
        if status == noErr && ref != nil {
            registrationFailures.remove(slot)
        } else {
            registrationFailures.insert(slot)
        }
    }

    private func unregister(_ slot: Slot) {
        if let ref = hotKeyRefs[slot] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[slot] = nil
        }
    }
}
