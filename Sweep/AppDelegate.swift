import AppKit
import SwiftUI

extension Notification.Name {
    static let sweepPanelDidOpen = Notification.Name("sweepPanelDidOpen")
    static let sweepPanelDidClose = Notification.Name("sweepPanelDidClose")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerFeatures()
        FeatureRegistry.shared.bootstrap()

        SweepCoordinator.shared.onStateChange = { [weak self] swept in
            self?.updateStatusIcon(swept: swept)
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(registry: .shared))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = statusImage(swept: false)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        HotkeyManager.shared.action = {
            SweepCoordinator.shared.toggleSweepAll()
        }
        HotkeyManager.shared.clipboardAction = {
            ClipboardBezelController.shared.showOrAdvance()
        }
        HotkeyManager.shared.start()

        SweepCoordinator.shared.refreshState()
        updateStatusIcon(swept: SweepCoordinator.shared.isSwept)

        // Panel buttons ask for a specific settings tab.
        NotificationCenter.default.addObserver(
            forName: .sweepOpenSettings, object: nil, queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?["section"] as? String ?? ""
            self?.openSettings(section: SettingsSection(rawValue: raw) ?? .general)
        }
        NotificationCenter.default.addObserver(
            forName: .sweepClosePanel, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        // Menu bar, Dynamic Island, or both (General settings).
        applyInterfaceMode()
        NotificationCenter.default.addObserver(
            forName: .sweepInterfaceModeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyInterfaceMode()
        }

        offerRecoveryIfNeeded()
        showOnboardingIfNeeded()
    }

    private func applyInterfaceMode() {
        let mode = InterfaceMode.current
        statusItem?.isVisible = mode.showsStatusItem
        DynamicIslandController.shared.setVisible(mode.showsIsland)
        if !mode.showsStatusItem, popover.isShown {
            popover.performClose(nil)
        }
    }

    private var onboardingWindowController: OnboardingWindowController?

    /// First launch only: 3 short screens (Phase 6).
    private func showOnboardingIfNeeded() {
        let key = "hasCompletedOnboarding"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let controller = OnboardingWindowController { [weak self] in
            UserDefaults.standard.set(true, forKey: key)
            self?.onboardingWindowController?.close()
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        FeatureRegistry.shared.appWillTerminate()
    }

    /// Fixed module order; this is also the panel card order (FR-1.2).
    private func registerFeatures() {
        let registry = FeatureRegistry.shared
        registry.register(DesktopSweepModule.shared)
        registry.register(AppSweepModule.shared)
        registry.register(ClipboardModule.shared)
    }

    /// FR-2.3: if the app quit or crashed while swept, offer to restore.
    private func offerRecoveryIfNeeded() {
        let desktopSwept = DesktopSweepModule.shared.isSwept
        let appsSwept = AppSweepModule.shared.isSwept
        guard desktopSwept || appsSwept else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Sweep is still active", comment: "")
        alert.informativeText = NSLocalizedString("Sweep was closed while things were swept away. Your files and apps are untouched. Restore everything now?", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restore", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Keep Swept", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            // Restore directly on the modules: recovery must work even if the
            // feature toggles were somehow left off while the state says swept.
            if desktopSwept { DesktopSweepModule.shared.restore() }
            if appsSwept { AppSweepModule.shared.restore() }
        }
    }

    private func updateStatusIcon(swept: Bool) {
        statusItem?.button?.image = statusImage(swept: swept)
    }

    /// The same sweep mark as the app icon, as a menu-bar template.
    /// A dot in the corner means the desktop is currently swept.
    private func statusImage(swept: Bool) -> NSImage {
        let fallback = NSImage(systemSymbolName: swept ? "wind.circle.fill" : "wind",
                               accessibilityDescription: "Sweep")
        guard let base = NSImage(named: "MenuBarIcon") else { return fallback ?? NSImage() }
        base.isTemplate = true
        base.accessibilityDescription = "Sweep"
        guard swept else { return base }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let diameter = max(3.5, rect.width * 0.22)
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.maxX - diameter,
                                                   y: rect.maxY - diameter,
                                                   width: diameter,
                                                   height: diameter))
            NSColor.black.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Sweep"
        return image
    }

    // MARK: - Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            repositionPanel()
        }
    }

    /// Keep the panel fully on screen, directly below the menu bar icon.
    /// (NSPopover can mis-anchor from a status item and spill past the top
    /// edge, especially after its SwiftUI content changes height.)
    private func repositionPanel() {
        guard let button = statusItem.button,
              let panelWindow = popover.contentViewController?.view.window,
              let iconWindow = button.window,
              let screen = iconWindow.screen ?? NSScreen.main else { return }

        let iconFrame = iconWindow.frame
        var frame = panelWindow.frame
        frame.origin.x = iconFrame.midX - frame.width / 2   // centered under the icon
        frame.origin.y = iconFrame.minY - frame.height      // top edge below the menu bar

        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = max(frame.origin.y, visible.minY + 8)
        if frame != panelWindow.frame {
            panelWindow.setFrame(frame, display: true)
        }
    }

    private var panelResizeObserver: NSObjectProtocol?

    func popoverWillShow(_ notification: Notification) {
        NotificationCenter.default.post(name: .sweepPanelDidOpen, object: nil)
    }

    func popoverDidShow(_ notification: Notification) {
        repositionPanel()
        // Re-clamp whenever live content (countdown, stats) changes the height.
        if let panelWindow = popover.contentViewController?.view.window {
            panelResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: panelWindow, queue: .main
            ) { [weak self] _ in
                self?.repositionPanel()
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let panelResizeObserver {
            NotificationCenter.default.removeObserver(panelResizeObserver)
            self.panelResizeObserver = nil
        }
        NotificationCenter.default.post(name: .sweepPanelDidClose, object: nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let featuresItem = NSMenuItem(title: NSLocalizedString("Manage Features…", comment: ""),
                                      action: #selector(openFeatureSettings), keyEquivalent: "")
        featuresItem.target = self
        menu.addItem(featuresItem)

        let settingsItem = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""),
                                      action: #selector(openGeneralSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit Sweep", comment: ""),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Assigning a menu makes the next click show it; clear it afterwards so
        // left-click keeps opening the popover instead.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Settings

    @objc func openGeneralSettings() {
        openSettings(section: .general)
    }

    @objc func openFeatureSettings() {
        openSettings(section: .features)
    }

    func openSettings(section: SettingsSection) {
        SettingsState.shared.open(section)
        if popover.isShown {
            popover.performClose(nil)
        }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}
