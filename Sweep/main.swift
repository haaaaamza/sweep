import AppKit

// AppKit lifecycle: Sweep is a menu bar (LSUIElement) app with no main window,
// so we own the NSApplication run loop directly and host SwiftUI views where needed.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

