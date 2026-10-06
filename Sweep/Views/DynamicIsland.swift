import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted when the user changes where Sweep lives (menu bar / island / both).
    static let sweepInterfaceModeChanged = Notification.Name("sweepInterfaceModeChanged")
}

/// Where Sweep's UI lives (derived from the Dynamic Island settings).
enum InterfaceMode: String, CaseIterable, Identifiable {
    case menuBar
    case island
    case both

    var id: String { rawValue }

    static var current: InterfaceMode {
        get {
            InterfaceMode(rawValue: UserDefaults.standard.string(forKey: "interface.mode") ?? "")
                ?? .menuBar
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "interface.mode")
            NotificationCenter.default.post(name: .sweepInterfaceModeChanged, object: nil)
        }
    }

    var showsStatusItem: Bool { self != .island }
    var showsIsland: Bool { self != .menuBar }
}

// MARK: - Island preferences

/// The island's expanded size.
enum IslandSize: String, CaseIterable, Identifiable {
    case compact
    case spacious
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return String(localized: "Compact")
        case .spacious: return String(localized: "Spacious")
        case .custom: return String(localized: "Custom")
        }
    }

    /// Fixed height of a page's content area — every page shares one canvas
    /// so the panel never jumps size when you switch pages.
    var contentHeight: CGFloat { self == .compact ? 224 : 258 }
}

/// A quick-action tile the user can show in the island's Quick access grid.
enum IslandTile: String, CaseIterable, Identifiable {
    case volumeMixer
    case nowPlaying
    case system
    case calendar
    case notifications
    case timer
    case downloads
    case aiAgents
    case keepAwake
    case clipboard

    var id: String { rawValue }

    var name: String {
        switch self {
        case .volumeMixer: return String(localized: "Volume mixer")
        case .nowPlaying: return String(localized: "Now Playing")
        case .system: return String(localized: "System")
        case .calendar: return String(localized: "Calendar")
        case .notifications: return String(localized: "Notifications")
        case .timer: return String(localized: "Timer")
        case .downloads: return String(localized: "Downloads")
        case .aiAgents: return String(localized: "AI Agents")
        case .keepAwake: return String(localized: "Keep awake")
        case .clipboard: return String(localized: "Clipboard")
        }
    }

    var icon: String {
        switch self {
        case .volumeMixer: return "speaker.wave.2.fill"
        case .nowPlaying: return "music.note"
        case .system: return "gauge.with.needle"
        case .calendar: return "calendar"
        case .notifications: return "bell.fill"
        case .timer: return "timer"
        case .downloads: return "arrow.down.circle"
        case .aiAgents: return "sparkles"
        case .keepAwake: return "moon.fill"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    var tint: Color {
        switch self {
        case .volumeMixer: return .white
        case .nowPlaying: return .pink
        case .system: return .white
        case .calendar: return .red
        case .notifications: return .white
        case .timer: return .orange
        case .downloads: return .white
        case .aiAgents: return .orange
        case .keepAwake: return .orange
        case .clipboard: return .teal
        }
    }

    /// The feature that must be enabled for the tile to work (nil = always).
    var requiredFeatureID: String? {
        switch self {
        case .system: return "system-glance"
        case .keepAwake: return "keep-awake"
        case .clipboard: return "clipboard"
        default: return nil
        }
    }

    /// The island page this tile opens.
    var page: IslandPage {
        switch self {
        case .volumeMixer: return .volumeMixer
        case .nowPlaying: return .nowPlaying
        case .system: return .system
        case .calendar: return .calendar
        case .notifications: return .notifications
        case .timer: return .timer
        case .downloads: return .downloads
        case .aiAgents: return .aiAgents
        case .keepAwake: return .keepAwake
        case .clipboard: return .clipboard
        }
    }
}

/// Everything customizable about the island, persisted and applied live.
final class IslandPrefs: ObservableObject {
    static let shared = IslandPrefs()

    @Published var islandEnabled: Bool {
        didSet {
            if !islandEnabled { hideMenuBarIcon = false }
            applyMode()
        }
    }
    /// Island-only mode: the menu bar icon disappears.
    @Published var hideMenuBarIcon: Bool {
        didSet { applyMode() }
    }
    @Published var size: IslandSize {
        didSet { UserDefaults.standard.set(size.rawValue, forKey: "island.size") }
    }
    @Published var customWidth: Double {
        didSet { UserDefaults.standard.set(customWidth, forKey: "island.customWidth") }
    }
    @Published var customMaxHeight: Double {
        didSet { UserDefaults.standard.set(customMaxHeight, forKey: "island.customMaxHeight") }
    }
    @Published var showOutline: Bool {
        didSet { UserDefaults.standard.set(showOutline, forKey: "island.outline") }
    }
    @Published var tiles: Set<String> {
        didSet { UserDefaults.standard.set(Array(tiles), forKey: "island.tiles") }
    }

    var expandedWidth: CGFloat {
        switch size {
        case .compact: return 560
        case .spacious: return 640
        case .custom: return CGFloat(customWidth)
        }
    }

    var contentHeight: CGFloat {
        switch size {
        case .custom: return max(170, CGFloat(customMaxHeight) - 76)
        default: return size.contentHeight
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        let mode = InterfaceMode.current
        islandEnabled = mode.showsIsland
        hideMenuBarIcon = mode == .island
        size = IslandSize(rawValue: defaults.string(forKey: "island.size") ?? "") ?? .spacious
        customWidth = defaults.object(forKey: "island.customWidth") as? Double ?? 640
        customMaxHeight = defaults.object(forKey: "island.customMaxHeight") as? Double ?? 340
        showOutline = defaults.object(forKey: "island.outline") as? Bool ?? false
        if let stored = defaults.stringArray(forKey: "island.tiles") {
            tiles = Set(stored)
        } else {
            tiles = Set(IslandTile.allCases.map(\.rawValue))
        }
    }

    private func applyMode() {
        let mode: InterfaceMode = islandEnabled ? (hideMenuBarIcon ? .island : .both) : .menuBar
        guard mode != InterfaceMode.current else { return }
        InterfaceMode.current = mode
    }

    func showsTile(_ tile: IslandTile) -> Bool {
        tiles.contains(tile.rawValue)
    }

    func bindingForTile(_ tile: IslandTile) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.showsTile(tile) ?? false },
            set: { [weak self] shown in
                guard let self else { return }
                if shown { tiles.insert(tile.rawValue) } else { tiles.remove(tile.rawValue) }
            }
        )
    }
}

// MARK: - Island window

/// An iPhone-style Dynamic Island hugging the notch (or floating top-center on
/// Macs without one). Collapsed it's hidden behind the notch; move the mouse
/// there and it slides out, then expands into Sweep's controls hub.
final class DynamicIslandController: ObservableObject {
    static let shared = DynamicIslandController()

    @Published var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            // Drives the System Glance sampler exactly like the popover does.
            NotificationCenter.default.post(
                name: isExpanded ? .sweepPanelDidOpen : .sweepPanelDidClose, object: nil)
            resizeToFit(animated: true)
        }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingController<IslandRootView>?
    private var observers: [NSObjectProtocol] = []

    func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil { build() }
            resizeToFit()
            panel?.orderFrontRegardless()
        } else {
            if isExpanded { isExpanded = false }
            panel?.orderOut(nil)
        }
    }

    func collapse() {
        isExpanded = false
    }

    private func build() {
        let hosting = NSHostingController(rootView: IslandRootView(island: self,
                                                                   registry: .shared))
        self.hosting = hosting

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: collapsedSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No window shadow: the panel is transparent, so macOS would draw a hard
        // silhouette shadow around every opaque shape (each satellite circle),
        // which reads as an ugly black ring. Depth comes from SwiftUI shadows.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.panel = panel

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.resizeToFit() })
    }

    /// Size the window to exactly fit the current content (pill or hub),
    /// anchored top-center. An exact fit is what keeps the black shape tight —
    /// a window larger than its content reads as a floating black box.
    /// Animated, the frame grows/shrinks from the top edge in sync with the
    /// SwiftUI content transition, so the hub reads as growing out of the pill.
    private func resizeToFit(animated: Bool = false) {
        guard let panel, let hosting else { return }
        hosting.view.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, let screen = self.targetScreen else { return }
            let size = self.isExpanded ? hosting.view.fittingSize : self.collapsedSize
            let topY = self.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - 4
            let frame = NSRect(x: screen.frame.midX - size.width / 2,
                               y: topY - size.height,
                               width: size.width, height: size.height)
            guard panel.frame != frame else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.44
                    // A gentle decelerating curve that mirrors the content's
                    // spring, so the window and the hub arrive together.
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1)
                    context.allowsImplicitAnimation = true
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
    }

    /// Prefer the screen that actually has a notch; else the main screen.
    var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    var hasNotch: Bool {
        (targetScreen?.safeAreaInsets.top ?? 0) > 0
    }

    /// Collapsed pill metrics: wraps the physical notch when there is one.
    var collapsedSize: CGSize {
        guard let screen = targetScreen else { return CGSize(width: 190, height: 30) }
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let notchWidth = max(screen.frame.width - left - right, 150)
            return CGSize(width: notchWidth + 44, height: screen.safeAreaInsets.top + 4)
        }
        return CGSize(width: 190, height: 30)
    }
}

// MARK: - Hub shape

/// The expanded hub's silhouette: full-width at the very top so it blends into
/// the menu bar, then the sides scoop inward (the classic notch flare) and the
/// bottom corners get a big continuous radius.
struct NotchHubShape: Shape {
    var flare: CGFloat = 14
    var bottomRadius: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                       control: CGPoint(x: rect.minX + flare, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + flare + bottomRadius, y: rect.maxY),
                       control: CGPoint(x: rect.minX + flare, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - flare - bottomRadius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - bottomRadius),
                       control: CGPoint(x: rect.maxX - flare, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - flare, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Pages

/// Every page the hub can show. `controls` is home.
enum IslandPage: String, CaseIterable, Identifiable {
    case controls
    case grid
    case volumeMixer
    case nowPlaying
    case system
    case network
    case calendar
    case notifications
    case timer
    case downloads
    case aiAgents
    case keepAwake
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controls: return String(localized: "Controls")
        case .grid: return String(localized: "Quick access")
        case .volumeMixer: return String(localized: "Volume mixer")
        case .nowPlaying: return String(localized: "Now Playing")
        case .system: return String(localized: "System")
        case .network: return String(localized: "Network")
        case .calendar: return String(localized: "Calendar")
        case .notifications: return String(localized: "Notifications")
        case .timer: return String(localized: "Timer")
        case .downloads: return String(localized: "Downloads")
        case .aiAgents: return String(localized: "AI Agents")
        case .keepAwake: return String(localized: "Keep Awake")
        case .clipboard: return String(localized: "Clipboard")
        }
    }

    var icon: String {
        switch self {
        case .controls: return "slider.horizontal.3"
        case .grid: return "square.grid.2x2"
        case .volumeMixer: return "speaker.wave.2.fill"
        case .nowPlaying: return "music.note"
        case .system: return "gauge.with.needle"
        case .network: return "globe"
        case .calendar: return "calendar"
        case .notifications: return "bell.fill"
        case .timer: return "timer"
        case .downloads: return "arrow.down.circle"
        case .aiAgents: return "sparkles"
        case .keepAwake: return "moon.fill"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    var accent: Color {
        switch self {
        case .nowPlaying: return .pink
        case .calendar: return .red
        case .timer, .aiAgents, .keepAwake: return .orange
        case .clipboard: return .teal
        default: return .white
        }
    }

    /// The display string for its global shortcut (shown in the grid).
    var shortcutDisplay: String? {
        switch self {
        case .controls: return "⌥⌘C"
        case .volumeMixer: return "⌥⌘V"
        case .nowPlaying: return "⌥⌘M"
        case .system: return "⌥⌘I"
        case .calendar: return "⌥⌘A"
        case .notifications: return "⌥⌘N"
        case .timer: return "⌥⌘R"
        case .downloads: return "⌥⌘D"
        case .aiAgents: return "⌥⌘G"
        default: return nil
        }
    }

    /// The feature that must be enabled for this page's data (nil = always).
    var requiredFeatureID: String? {
        switch self {
        case .system: return "system-glance"
        case .keepAwake: return "keep-awake"
        case .clipboard: return "clipboard"
        default: return nil
        }
    }
}

// MARK: - Root view

/// The hub's "extract from the notch" transition: it unfurls downward from the
/// top edge while fading in, so it reads as being pulled out of the notch rather
/// than zooming in from nothing.
private struct IslandUnfurl: ViewModifier {
    var progress: Double
    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.92 + 0.08 * progress, y: 0.16 + 0.84 * progress, anchor: .top)
            .opacity(min(progress * 1.4, 1))
    }
}

extension AnyTransition {
    static var island: AnyTransition {
        .modifier(active: IslandUnfurl(progress: 0), identity: IslandUnfurl(progress: 1))
    }
}

struct IslandRootView: View {
    @ObservedObject var island: DynamicIslandController
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var prefs = IslandPrefs.shared
    @ObservedObject var coordinator = SweepCoordinator.shared
    @ObservedObject var keepAwake = KeepAwakeModule.shared
    @ObservedObject var apps = AppSweepModule.shared

    /// The pill stays tucked away until the mouse reaches the notch area.
    @State private var isRevealed = false
    @State private var expandWork: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .top) {
            if island.isExpanded {
                IslandHubView(island: island, registry: registry)
                    .transition(.island)
            } else {
                collapsed
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        // One continuous spring so the hub unfurls from the notch in lockstep
        // with the window growing beneath it.
        .animation(.spring(response: 0.44, dampingFraction: 0.82), value: island.isExpanded)
        .onChange(of: island.isExpanded) { _, expanded in
            if !expanded { isRevealed = false }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Collapsed state: an invisible hover strip hugging the notch. Moving the
    /// mouse there slides the pill out; lingering (or clicking) opens the hub.
    private var collapsed: some View {
        let size = island.collapsedSize
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: island.hasNotch ? 0 : 14,
                               bottomLeading: 14,
                               bottomTrailing: 14,
                               topTrailing: island.hasNotch ? 0 : 14),
            style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: coordinator.isSwept ? "wind.circle.fill" : "wind")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(coordinator.isSwept ? Color.orange : .white)
            if island.hasNotch {
                Spacer(minLength: 0)
            }
            status
        }
        .padding(.horizontal, 14)
        .padding(.top, island.hasNotch ? 2 : 0)
        .frame(width: size.width, height: size.height)
        .background(shape.fill(.black))
        .overlay(prefs.showOutline ? shape.strokeBorder(.white.opacity(0.25), lineWidth: 1) : nil)
        // The pill peeks out of the notch the instant the mouse arrives, then
        // the hub extracts from it — a single, continuous reveal.
        .opacity(isRevealed ? 1 : 0)
        .scaleEffect(x: isRevealed ? 1 : 0.9, y: isRevealed ? 1 : 0.5, anchor: .top)
        .offset(y: isRevealed ? 0 : -size.height)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isRevealed)
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                isRevealed = true
                scheduleExpand()
            } else {
                expandWork?.cancel()
                isRevealed = false
            }
        }
        .onTapGesture {
            expandWork?.cancel()
            island.isExpanded = true
        }
    }

    /// Open the hub shortly after the mouse settles on the notch — long enough
    /// that a cursor merely passing the top edge doesn't trigger it, short
    /// enough that it feels immediate.
    private func scheduleExpand() {
        expandWork?.cancel()
        let work = DispatchWorkItem {
            if isRevealed && !island.isExpanded { island.isExpanded = true }
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if let remaining = apps.autoRestoreRemaining {
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text(KeepAwakeCard.format(remaining))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            if keepAwake.isSessionActive {
                HStack(spacing: 3) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 9))
                    if let remaining = keepAwake.remaining {
                        Text(KeepAwakeCard.format(remaining))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    }
                }
                .foregroundStyle(.orange)
            }
            if coordinator.isSwept {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            } else if !keepAwake.isSessionActive && apps.autoRestoreRemaining == nil && !island.hasNotch {
                Text("Sweep")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Expanded hub

/// The island's hub: a flared black panel with paged content, ringed by floating
/// circular satellite buttons (pages left, settings/volume right, music + alerts
/// at the bottom). Matches the reference "Croissant" layout.
struct IslandHubView: View {
    @ObservedObject var island: DynamicIslandController
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var prefs = IslandPrefs.shared
    @ObservedObject var coordinator = SweepCoordinator.shared
    @ObservedObject var desktop = DesktopSweepModule.shared
    @ObservedObject var apps = AppSweepModule.shared
    @ObservedObject var keepAwake = KeepAwakeModule.shared
    @ObservedObject var audio = SystemAudioModule.shared
    @ObservedObject var timers = TimerModule.shared
    @ObservedObject var nowPlaying = NowPlayingModule.shared

    @State private var page: IslandPage = .controls
    /// The page to return to with the back chevron (grid remembers it).
    @State private var backTarget: IslandPage = .controls

    private let flare: CGFloat = 14
    private let satelliteSize: CGFloat = 42

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                satelliteColumn([
                    .init(icon: "square.grid.2x2", help: String(localized: "Quick access"),
                          isActive: page == .grid) { switchTo(.grid) },
                    .init(icon: "timer", help: String(localized: "Timer"),
                          isActive: page == .timer || timers.isActive) { switchTo(.timer) },
                    .init(icon: "gauge.with.needle", help: String(localized: "System"),
                          isActive: page == .system) { switchTo(.system) },
                ])
                .padding(.top, 48)

                hubPanel

                satelliteColumn([
                    .init(icon: "gearshape.fill", help: String(localized: "Settings"),
                          isActive: false) { openSettings() },
                    .init(icon: "speaker.wave.1.fill", help: String(localized: "Volume down"),
                          isActive: false) { nudgeVolume(-0.1) },
                    .init(icon: "speaker.wave.3.fill", help: String(localized: "Volume up"),
                          isActive: false) { nudgeVolume(0.1) },
                ])
                .padding(.top, 48)
            }

            bottomSatellites
        }
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if !hovering { island.collapse() }
        }
        .onAppear { startSamplers() }
        .onDisappear { stopSamplers() }
    }

    // MARK: Panel

    private var hubPanel: some View {
        let shape = NotchHubShape(flare: island.hasNotch ? flare : 6, bottomRadius: 26)
        return VStack(spacing: 10) {
            header
            pageContent
                .frame(height: prefs.contentHeight, alignment: .top)
                .clipped()
        }
        .padding(.horizontal, flare + 14)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(width: prefs.expandedWidth)
        .background(
            shape.fill(.black)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        .overlay(shape.stroke(.white.opacity(prefs.showOutline ? 0.25 : 0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: page)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page != .controls {
                Button {
                    switchTo(page == .network ? .system : .controls)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if page == .grid {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text(page.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Menu {
                Button(String(localized: "Island Settings…")) { openSettings() }
                Button(String(localized: "Open Monitor…")) { openMonitor() }
                Divider()
                Button(String(localized: "Quit Sweep")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                island.collapse()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .controls:
            ControlsHomePage(registry: registry, onOpenPage: switchTo)
        case .grid:
            IslandGridPage(registry: registry, onOpenPage: switchTo,
                           onOpenSettings: openSettings, onOpenMonitor: openMonitor)
        case .volumeMixer:
            VolumeMixerPage()
        case .nowPlaying:
            NowPlayingPage()
        case .system:
            if registry.isEnabled("system-glance") {
                SystemPage(onOpenNetwork: { switchTo(.network) }, onOpenMonitor: openMonitor)
            } else {
                IslandFeatureOffPrompt(
                    featureID: "system-glance",
                    name: String(localized: "System Glance"),
                    caption: String(localized: "Live CPU, memory and disk readings. The sampler only runs while this hub is open."),
                    registry: registry)
            }
        case .network:
            NetworkPage()
        case .calendar:
            CalendarPage()
        case .notifications:
            NotificationsPage()
        case .timer:
            TimerPage()
        case .downloads:
            DownloadsPage()
        case .aiAgents:
            AIAgentsPage()
        case .keepAwake:
            if registry.isEnabled("keep-awake") {
                IslandKeepAwakePage()
            } else {
                IslandFeatureOffPrompt(
                    featureID: "keep-awake",
                    name: String(localized: "Keep Awake"),
                    caption: String(localized: "Stop your Mac from going to sleep, for a while or indefinitely. No permissions needed."),
                    registry: registry)
            }
        case .clipboard:
            if registry.isEnabled("clipboard") {
                IslandClipboardPage(onCollapse: { island.collapse() })
            } else {
                IslandFeatureOffPrompt(
                    featureID: "clipboard",
                    name: String(localized: "Clipboard History"),
                    caption: String(localized: "Remembers what you copy — text and images — and pastes any of it back, anywhere."),
                    registry: registry)
            }
        }
    }

    // MARK: Satellites

    struct Satellite: Identifiable {
        let icon: String
        let help: String
        let isActive: Bool
        let action: () -> Void
        var id: String { icon }
    }

    private func satelliteColumn(_ satellites: [Satellite]) -> some View {
        VStack(spacing: 12) {
            ForEach(satellites) { satellite in
                satelliteButton(satellite, diameter: satelliteSize)
            }
        }
    }

    private var bottomSatellites: some View {
        HStack(spacing: 14) {
            satelliteButton(.init(icon: "music.note",
                                  help: String(localized: "Now Playing"),
                                  isActive: page == .nowPlaying) { switchTo(.nowPlaying) },
                            diameter: satelliteSize)
            satelliteButton(.init(icon: "bell.fill",
                                  help: String(localized: "Notifications"),
                                  isActive: page == .notifications) { switchTo(.notifications) },
                            diameter: satelliteSize)
        }
    }

    private func satelliteButton(_ satellite: Satellite, diameter: CGFloat,
                                 dimmed: Bool = false) -> some View {
        Button(action: satellite.action) {
            Image(systemName: satellite.icon)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(satellite.isActive ? Color.orange : .white)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(dimmed ? Color(white: 0.42).opacity(0.9)
                                         : Color(white: 0.11))
                )
                .overlay(
                    satellite.isActive
                        ? Circle().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1)
                        : nil
                )
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(satellite.help)
    }

    // MARK: Actions

    private func switchTo(_ newPage: IslandPage) {
        page = (page == newPage && newPage != .controls) ? .controls : newPage
    }

    private func nudgeVolume(_ delta: Double) {
        audio.setMasterVolume(min(max(audio.masterVolume + delta, 0), 1))
    }

    private func startSamplers() {
        audio.start()
        if nowPlaying.isAvailable { nowPlaying.start() }
    }

    private func stopSamplers() {
        audio.stop()
        nowPlaying.stop()
    }

    private func openSettings() {
        island.collapse()
        NotificationCenter.default.post(name: .sweepOpenSettings, object: nil,
                                        userInfo: ["section": SettingsSection.island.rawValue])
    }

    private func openMonitor() {
        island.collapse()
        NotificationCenter.default.post(name: .sweepOpenMonitor, object: nil)
    }
}

// MARK: - Shared chrome

/// The dark rounded card every page is built from.
struct IslandCard: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    func islandCard(padding: CGFloat = 12) -> some View {
        modifier(IslandCard(padding: padding))
    }
}

/// "icon + bold title" header used at the top of every card.
struct CardHeader: View {
    let icon: String
    let title: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// A thin capsule progress bar.
struct IslandProgressBar: View {
    var fraction: Double
    var tint: Color = .orange
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Feature-off prompt

/// Shown when a page's feature is disabled.
struct IslandFeatureOffPrompt: View {
    let featureID: String
    let name: String
    let caption: String
    @ObservedObject var registry: FeatureRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                Text(name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Off")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button {
                    registry.setEnabled(featureID, true)
                } label: {
                    Text("Turn on")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    NotificationCenter.default.post(name: .sweepOpenSettings, object: nil,
                                                    userInfo: ["section": SettingsSection.features.rawValue])
                } label: {
                    Text("Open Settings…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }
}

// MARK: - Settings page

struct IslandSettingsPage: View {
    @ObservedObject var prefs = IslandPrefs.shared
    @ObservedObject var registry = FeatureRegistry.shared

    var body: some View {
        SettingsPageScaffold(
            title: String(localized: "Dynamic Island"),
            subtitle: String(localized: "Your music, controls and everyday tools, together at the top of your screen. Hidden until you move the mouse to the notch, then it slides out. Changes apply live.")
        ) {
            SettingsCard {
                SettingsRow(icon: "oval.fill",
                            tint: .blue,
                            title: String(localized: "Show the Dynamic Island"),
                            caption: String(localized: "Hidden until you move the mouse to the notch — then it slides out and opens the controls hub.")) {
                    Toggle("", isOn: $prefs.islandEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                CardDivider()
                SettingsRow(icon: "menubar.rectangle",
                            tint: .gray,
                            title: String(localized: "Hide the menu bar icon"),
                            caption: String(localized: "Island only — Settings and Quit stay reachable from the island.")) {
                    Toggle("", isOn: $prefs.hideMenuBarIcon)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!prefs.islandEnabled)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Layout").font(.headline)
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        ChipPicker(
                            options: IslandSize.allCases.map { ($0.label, $0) },
                            selection: $prefs.size
                        )
                        if prefs.size == .custom {
                            HStack(spacing: 10) {
                                Text("Width").font(.caption)
                                Slider(value: $prefs.customWidth, in: 480...820, step: 5)
                                Text("\(Int(prefs.customWidth))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            HStack(spacing: 10) {
                                Text("Maximum height").font(.caption)
                                Slider(value: $prefs.customMaxHeight, in: 260...480, step: 5)
                                Text("\(Int(prefs.customMaxHeight))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            Text("The hub's panel size. Pages scroll when their content is longer.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("How roomy the expanded island is.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    CardDivider()
                    SettingsRow(icon: "circle.dashed",
                                tint: .teal,
                                title: String(localized: "Show outline"),
                                caption: String(localized: "A subtle border so the island stands out on dark wallpapers.")) {
                        Toggle("", isOn: $prefs.showOutline)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick access grid").font(.headline)
                SettingsCard {
                    ForEach(Array(IslandTile.allCases.enumerated()), id: \.element) { index, tile in
                        if index > 0 { CardDivider() }
                        SettingsRow(icon: tile.icon,
                                    tint: tile.tint == .white ? .gray : tile.tint,
                                    title: tile.name,
                                    caption: tileCaption(tile)) {
                            Toggle("", isOn: prefs.bindingForTile(tile))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .disabled(!tileAvailable(tile))
                        }
                    }
                }
                Text("These control which tiles appear in the Quick access grid. Satellite buttons and the Controls home follow the features you have enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tileAvailable(_ tile: IslandTile) -> Bool {
        guard let feature = tile.requiredFeatureID else { return true }
        return registry.isEnabled(feature)
    }

    private func tileCaption(_ tile: IslandTile) -> String {
        let base: String
        switch tile {
        case .volumeMixer: base = String(localized: "Per-app volume sliders.")
        case .nowPlaying: base = String(localized: "The current track and transport controls.")
        case .system: base = String(localized: "Live CPU, memory, battery and network.")
        case .calendar: base = String(localized: "Your upcoming events.")
        case .notifications: base = String(localized: "Mirror notification banners in the island.")
        case .timer: base = String(localized: "Timer, Pomodoro and stopwatch.")
        case .downloads: base = String(localized: "Recent files from your watched folder.")
        case .aiAgents: base = String(localized: "Local Claude Code usage and cost.")
        case .keepAwake: base = String(localized: "Keep your Mac awake, timed or indefinitely.")
        case .clipboard: base = String(localized: "Your clipboard history.")
        }
        if !tileAvailable(tile) {
            return base + " " + String(localized: "(Enable the feature first.)")
        }
        return base
    }
}
