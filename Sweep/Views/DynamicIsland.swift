import SwiftUI
import AppKit
import QuartzCore

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
    case clipboard

    var id: String { rawValue }

    var name: String {
        switch self {
        case .clipboard: return String(localized: "Clipboard")
        }
    }

    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        }
    }

    var tint: Color {
        switch self {
        case .clipboard: return .teal
        }
    }

    /// The feature that must be enabled for the tile to work (nil = always).
    var requiredFeatureID: String? {
        switch self {
        case .clipboard: return "clipboard"
        }
    }

    /// The island page this tile opens.
    var page: IslandPage {
        switch self {
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
        let known = Set(IslandTile.allCases.map(\.rawValue))
        if let stored = defaults.stringArray(forKey: "island.tiles") {
            tiles = Set(stored).intersection(known)
            if tiles.isEmpty { tiles = known }
        } else {
            tiles = known
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

/// Opening and closing springs from NotchAnimationDemo (boring.notch's values).
private enum StandardAnimations {
    static let enableOpeningAnimation = true
    static let animationSpeedMultiplier: Double = 1.0

    static let interactive = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    static var open: Animation {
        guard enableOpeningAnimation else { return .linear(duration: 0) }
        return .spring(response: 0.42 / animationSpeedMultiplier, dampingFraction: 0.8, blendDuration: 0)
    }

    static var close: Animation {
        guard enableOpeningAnimation else { return .linear(duration: 0) }
        return .spring(response: 0.45 / animationSpeedMultiplier, dampingFraction: 1.0, blendDuration: 0)
    }
}

/// Room under the open notch so its shadow is not cut by the window.
private let islandShadowPadding: CGFloat = 20

/// Closed and open corner radii, copied from NotchAnimationDemo.
private let islandCornerRadiusInsets: (
    opened: (top: CGFloat, bottom: CGFloat),
    closed: (top: CGFloat, bottom: CGFloat)
) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

final class DynamicIslandController: ObservableObject {
    static let shared = DynamicIslandController()

    @Published var isExpanded = false {
        didSet {
            guard oldValue != isExpanded else { return }
            if isExpanded { clearPulse() }
            applyFrame()
            NotificationCenter.default.post(
                name: isExpanded ? .sweepPanelDidOpen : .sweepPanelDidClose, object: nil)
        }
    }

    /// Transient widen-and-message state (charging, Sweep, low battery, …).
    @Published private(set) var activePulse: IslandPulse?

    /// Natural size of the whole hub, including the satellite buttons.
    private(set) var expandedWindowSize: CGSize?

    /// True while the pointer is over the island window. SwiftUI hover does not
    /// fire on this panel until it has been clicked, because the panel never
    /// becomes key.
    @Published private(set) var isPointerInside = false

    private var panel: NSPanel?
    private var hosting: FlushHostingView<IslandRootView>?
    private var observers: [NSObjectProtocol] = []
    private var pulseDismissTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hoverPoll: Timer?
    /// Set false by the close button so the poll does not reopen while the
    /// pointer is still sitting on the island. Armed again once it leaves.
    private var hoverOpenArmed = true

    func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil { build() }
            applyFrame()
            panel?.orderFrontRegardless()
            startHoverWatch()
            SystemPowerMonitor.shared.start()
        } else {
            stopHoverWatch()
            clearPulse()
            SystemPowerMonitor.shared.stop()
            if isExpanded { isExpanded = false }
            panel?.orderOut(nil)
        }
    }

    /// Open from a click on the closed notch. Marks the pointer as inside so
    /// a missed hover event cannot close it again immediately.
    func openFromPointer() {
        hoverOpenArmed = true
        isPointerInside = true
        guard !isExpanded else { return }
        withAnimation(StandardAnimations.interactive) {
            isExpanded = true
        }
    }

    /// Hover entered or left. Ignored exits while the cursor is still inside
    /// the window — resizing the panel on open sends a false leave.
    func pointerHoverChanged(_ hovering: Bool) {
        if !hovering && containsPointer() { return }
        if !hovering { hoverOpenArmed = true }
        if hovering && !hoverOpenArmed { return }
        guard hovering != isPointerInside else { return }
        isPointerInside = hovering
        hoverTask?.cancel()
        if hovering {
            guard !isExpanded else { return }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, !self.isExpanded, self.isPointerInside else { return }
                withAnimation(StandardAnimations.interactive) {
                    self.isExpanded = true
                }
            }
        } else {
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !self.isPointerInside else { return }
                if self.containsPointer() {
                    self.isPointerInside = true
                    return
                }
                withAnimation(StandardAnimations.interactive) {
                    self.isExpanded = false
                }
            }
        }
    }

    /// SwiftUI's hover tracking stays silent on a non-key panel. A short poll
    /// notices the cursor sitting on the notch even when mouse-enter never arrives.
    private func startHoverWatch() {
        guard hoverPoll == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.notePointerLocation()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPoll = timer
        notePointerLocation()
    }

    private func stopHoverWatch() {
        hoverPoll?.invalidate()
        hoverPoll = nil
        hoverTask?.cancel()
        hoverTask = nil
        isPointerInside = false
    }

    private func notePointerLocation() {
        pointerHoverChanged(containsPointer())
    }

    func collapse() {
        guard isExpanded else { return }
        hoverOpenArmed = false
        isPointerInside = false
        hoverTask?.cancel()
        isExpanded = false
    }

    /// Expand the closed notch horizontally, show a short status, then collapse.
    func presentPulse(_ pulse: IslandPulse) {
        guard InterfaceMode.current.showsIsland else { return }
        // Full hub already open — skip; the user is interacting.
        guard !isExpanded else { return }
        pulseDismissTask?.cancel()
        activePulse = pulse
        applyFrame()
        let id = pulse.id
        let duration = pulse.duration
        pulseDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            if activePulse?.id == id {
                activePulse = nil
                applyFrame()
            }
        }
    }

    func clearPulse() {
        pulseDismissTask?.cancel()
        pulseDismissTask = nil
        if activePulse != nil { activePulse = nil }
        applyFrame()
    }

    func containsPointer() -> Bool {
        guard let panel else { return false }
        return panel.frame.contains(NSEvent.mouseLocation)
    }

    func noteHubSize(_ size: CGSize) {
        guard size.width > 80, size.height > collapsedSize.height + 20 else { return }
        if let current = expandedWindowSize,
           abs(current.width - size.width) < 0.5,
           abs(current.height - size.height) < 0.5 {
            return
        }
        expandedWindowSize = size
        scheduleFrame()
    }

    /// setFrame during a SwiftUI layout pass re-enters layout and beachballs.
    private var frameTicket = 0
    private func scheduleFrame() {
        frameTicket += 1
        let ticket = frameTicket
        DispatchQueue.main.async { [weak self] in
            guard let self, self.frameTicket == ticket else { return }
            self.applyFrame()
        }
    }

    private func build() {
        let hosting = FlushHostingView(rootView: IslandRootView(island: self, registry: .shared))
        // The screen notch is a safe-area inset. Leaving it on pushes the
        // black bar down below the camera, so the pointer never hits it.
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hosting = hosting

        let container = IslandPassThroughView()
        container.onHoverChanged = { [weak self] hovering in
            self?.pointerHoverChanged(hovering)
        }
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: reservedWindowSize()),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = container
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.sharingType = .readOnly
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.panel = panel

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyFrame() })
    }

    func relayoutIfSettled() {
        applyFrame()
    }

    /// Top of the window is always the top of the screen. Closed, the window
    /// is only the notch strip — a tall invisible window was letting the bar
    /// drift down and stealing the pointer (spinning cursor, then a jump).
    private func applyFrame() {
        guard let panel, let screen = targetScreen else { return }
        let size = reservedWindowSize()
        let topY = screen.frame.maxY
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: topY - size.height,
                           width: max(size.width, 1),
                           height: max(size.height, 1))
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        panel.contentView?.updateTrackingAreas()
    }

    /// Open canvas: the hub, the closed strip the demo keeps above it, the
    /// open padding, and the shadow margin. Closed: just the notch.
    private func reservedWindowSize() -> CGSize {
        let closed = collapsedSize
        let pulseExtra: CGFloat = activePulse == nil ? 0 : 108 * 2
        let closedWidth = closed.width + pulseExtra + 36
        let closedHeight = closed.height + 16
        guard isExpanded else {
            return CGSize(width: closedWidth, height: closedHeight)
        }
        let hub = expandedWindowSize ?? CGSize(
            width: IslandPrefs.shared.expandedWidth + 108,
            height: IslandPrefs.shared.contentHeight + 180)
        let side = islandCornerRadiusInsets.opened.top + 12
        return CGSize(width: max(hub.width, closed.width) + side * 2,
                      height: hub.height + closed.height + 12 + 8 + islandShadowPadding)
    }

    /// Prefer the screen that actually has a notch; else the main screen.
    var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    var hasNotch: Bool {
        (targetScreen?.safeAreaInsets.top ?? 0) > 0
    }

    /// Closed notch size, matching NotchAnimationDemo's getClosedNotchSize().
    var collapsedSize: CGSize {
        guard let screen = targetScreen else { return CGSize(width: 185, height: 32) }
        var notchWidth: CGFloat = 185
        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
        }
        let notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        return CGSize(width: notchWidth, height: notchHeight)
    }
}

/// Hosting view that does not inherit the screen-notch safe area. That inset
/// was dropping the closed bar below the camera.
private final class FlushHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// Clicks in the clear part of the reserved window fall through to the desktop.
/// Tracking stays active when Sweep is not the front app, which is when
/// SwiftUI hover goes quiet until the first click.
private final class IslandPassThroughView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit == self ? nil : hit
    }
}

/// Notch outline from NotchAnimationDemo. The corner radii are animatable, so
/// they spring with the open and close.
private struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat? = nil, bottomCornerRadius: CGFloat? = nil) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
                          control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

// MARK: - Hub shape

/// The expanded hub's silhouette: a hard edge at the top of the screen, then
/// large continuous radii on the bottom corners.
struct NotchHubShape: Shape {
    var bottomRadius: CGFloat = 26

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let radius = min(bottomRadius, rect.width / 2, max(rect.height / 2, 0))
        // Square top, flush with the screen. Only the bottom corners round.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Pages

/// Every page the hub can show. `controls` is home.
enum IslandPage: String, CaseIterable, Identifiable {
    case controls
    case grid
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controls: return String(localized: "Controls")
        case .grid: return String(localized: "Quick access")
        case .clipboard: return String(localized: "Clipboard")
        }
    }

    var icon: String {
        switch self {
        case .controls: return "slider.horizontal.3"
        case .grid: return "square.grid.2x2"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    var accent: Color {
        switch self {
        case .clipboard: return .teal
        default: return .white
        }
    }

    /// The display string for its global shortcut (shown in the grid).
    var shortcutDisplay: String? {
        switch self {
        case .controls: return "⌥⌘C"
        case .clipboard: return HotkeyManager.shared.shortcut(for: .clipboard)?.display
        default: return nil
        }
    }

    /// The feature that must be enabled for this page's data (nil = always).
    var requiredFeatureID: String? {
        switch self {
        case .clipboard: return "clipboard"
        default: return nil
        }
    }
}

// MARK: - Root view

private struct IslandHubSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > value.width { value = next }
    }
}

struct IslandRootView: View {
    @ObservedObject var island: DynamicIslandController
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var prefs = IslandPrefs.shared
    @ObservedObject var coordinator = SweepCoordinator.shared
    @ObservedObject var apps = AppSweepModule.shared

    private var openedInsets: (top: CGFloat, bottom: CGFloat) { islandCornerRadiusInsets.opened }

    private var topCornerRadius: CGFloat {
        if island.isExpanded { return openedInsets.top }
        return displayClosedNotchHeight > 0 ? islandCornerRadiusInsets.closed.top : 0
    }

    private var currentNotchShape: NotchShape {
        let bottomCorner: CGFloat
        if island.isExpanded {
            bottomCorner = openedInsets.bottom
        } else {
            bottomCorner = displayClosedNotchHeight > 0 ? islandCornerRadiusInsets.closed.bottom : 0
        }
        return NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCorner)
    }

    private var displayClosedNotchHeight: CGFloat {
        island.collapsedSize.height == 0 ? 10 : island.collapsedSize.height
    }

    /// Outer height of the open shape: the closed strip, the hub, and the
    /// bottom padding the demo puts inside the frame.
    private var openFrameHeight: CGFloat? {
        guard let hub = island.expandedWindowSize else { return nil }
        return displayClosedNotchHeight + hub.height + 12
    }

    /// Physical camera / notch band — keep this empty; content lives in the wings.
    private var notchCoreWidth: CGFloat {
        max(island.collapsedSize.width - 20, 1)
    }

    /// Extra width on each side of the notch for pulse icon / percentage.
    private var pulseWingWidth: CGFloat { 108 }

    /// Content width of the closed / pulsing notch (grows outward for pulses).
    private var closedContentWidth: CGFloat {
        let core = notchCoreWidth
        if island.activePulse != nil {
            return core + pulseWingWidth * 2
        }
        return core
    }

    var body: some View {
        VStack(spacing: 0) {
            notchLayout
                .frame(height: island.isExpanded ? openFrameHeight : nil, alignment: .top)
                .animation(
                    island.isExpanded ? StandardAnimations.open : StandardAnimations.close,
                    value: island.isExpanded
                )
                .animation(StandardAnimations.open, value: island.activePulse?.id)
                .contentShape(Rectangle())
                .onHover { island.pointerHoverChanged($0) }
                .onTapGesture {
                    if !island.isExpanded { island.openFromPointer() }
                }
            Spacer(minLength: 0)
                .allowsHitTesting(false)
        }
        .padding(.bottom, island.isExpanded ? 8 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .compositingGroup()
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onChange(of: prefs.expandedWidth) { _, _ in island.relayoutIfSettled() }
        .onChange(of: prefs.contentHeight) { _, _ in island.relayoutIfSettled() }
        .onPreferenceChange(IslandHubSizeKey.self) { island.noteHubSize($0) }
        .background {
            if !island.isExpanded {
                IslandHubView(island: island, registry: registry, live: false)
                    .fixedSize()
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Closed: one black pill (demo). Open: black panel only — satellites sit
    /// outside that fill so wallpaper shows between them and the island.
    private var notchLayout: some View {
        Group {
            if island.isExpanded {
                IslandHubView(island: island, registry: registry)
                    .fixedSize()
                    .transition(
                        .scale(scale: 0.8, anchor: .top)
                            .combined(with: .opacity)
                            .animation(.smooth(duration: 0.35))
                    )
                    .allowsHitTesting(true)
            } else {
                closedPill
            }
        }
        .opacity(island.collapsedSize.height == 0 && !island.isExpanded ? 0.01 : 1)
    }

    private var closedPill: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .frame(width: closedContentWidth,
                       height: displayClosedNotchHeight)
            if let pulse = island.activePulse {
                pulseStatus(pulse)
            } else {
                closedStatus
            }
        }
        .padding(.horizontal, islandCornerRadiusInsets.closed.bottom)
        .background(.black)
        .clipShape(currentNotchShape)
        .overlay(alignment: .top) {
            displayClosedNotchHeight == 0
                ? nil
                : Rectangle()
                    .fill(.black)
                    .frame(height: 1)
                    .padding(.horizontal, topCornerRadius)
        }
        .shadow(
            color: (island.isPointerInside || island.activePulse != nil) ? .black.opacity(0.7) : .clear,
            radius: 6
        )
    }

    private func pulseStatus(_ pulse: IslandPulse) -> some View {
        HStack(spacing: 0) {
            // Left of the notch (icon + title).
            HStack(spacing: 6) {
                Image(systemName: pulse.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pulse.tint.color)
                    .symbolEffect(.bounce, value: pulse.id)
                Text(pulse.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.leading, 10)
            .frame(width: pulseWingWidth, alignment: .leading)

            // Camera / notch dead zone — nothing drawn here.
            Color.clear
                .frame(width: notchCoreWidth, height: displayClosedNotchHeight)

            // Right of the notch (percentage / detail).
            Group {
                if let detail = pulse.detail {
                    Text(detail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .monospacedDigit()
                }
            }
            .padding(.trailing, 10)
            .frame(width: pulseWingWidth, alignment: .trailing)
        }
        .frame(width: closedContentWidth, height: displayClosedNotchHeight)
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
    }

    private var closedStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: coordinator.isSwept ? "wind.circle.fill" : "wind")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(coordinator.isSwept ? Color.orange : .white)
            if island.hasNotch {
                Spacer(minLength: 0)
            }
            status
        }
        .padding(.horizontal, 10)
        .frame(width: closedContentWidth, height: displayClosedNotchHeight)
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            if let remaining = apps.autoRestoreRemaining {
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text(AppSweepModule.formatInterval(remaining))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            if coordinator.isSwept {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            } else if apps.autoRestoreRemaining == nil && !island.hasNotch {
                Text("Sweep")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}


// MARK: - Expanded hub

/// The island's hub: Sweep and Clipboard pages, with quick-access and settings
/// satellites on the sides.
struct IslandHubView: View {
    @ObservedObject var island: DynamicIslandController
    @ObservedObject var registry: FeatureRegistry
    /// False for the hidden copy that only measures the hub.
    var live: Bool = true
    @ObservedObject var prefs = IslandPrefs.shared

    @State private var page: IslandPage = .controls

    private let flare: CGFloat = 14
    private let satelliteSize: CGFloat = 42

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            satelliteColumn([
                .init(icon: "square.grid.2x2", help: String(localized: "Quick access"),
                      isActive: page == .grid) { switchTo(.grid) },
                .init(icon: "doc.on.clipboard", help: String(localized: "Clipboard"),
                      isActive: page == .clipboard) { switchTo(.clipboard) },
            ])
            .padding(.top, 48)

            // Black fill + clip live only on the panel. Satellites stay clear of it.
            openPanel

            satelliteColumn([
                .init(icon: "gearshape.fill", help: String(localized: "Settings"),
                      isActive: false) { openSettings() },
            ])
            .padding(.top, 48)
        }
        .padding(.bottom, 8)
        .fixedSize()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: IslandHubSizeKey.self, value: proxy.size)
            }
        }
    }

    // MARK: Panel

    private var openPanel: some View {
        let shape = NotchHubShape(bottomRadius: 26)
        return VStack(spacing: 0) {
            Color.clear.frame(height: max(island.collapsedSize.height, 1))
            VStack(spacing: 10) {
                header
                pageContent
                    .frame(height: prefs.contentHeight, alignment: .top)
                    .clipped()
            }
            .padding(.horizontal, flare + 14)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
        .frame(width: prefs.expandedWidth)
        .padding(.horizontal, openedPanelInsets)
        .padding(.bottom, 12)
        .background(.black, in: shape)
        .overlay(shape.stroke(.white.opacity(prefs.showOutline ? 0.25 : 0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.7), radius: 6)
        .animation(.easeOut(duration: 0.18), value: page)
    }

    private var openedPanelInsets: CGFloat {
        islandCornerRadiusInsets.opened.top
    }

    private var header: some View {
        HStack(spacing: 10) {
            if page != .controls {
                Button {
                    switchTo(.controls)
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
            IslandGridPage(registry: registry, onOpenPage: switchTo, onOpenSettings: openSettings)
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

    private func satelliteButton(_ satellite: Satellite, diameter: CGFloat) -> some View {
        Button(action: satellite.action) {
            Image(systemName: satellite.icon)
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(.black))
                .overlay(
                    Circle().strokeBorder(
                        satellite.isActive ? Color.orange.opacity(0.85) : Color.white.opacity(0.12),
                        lineWidth: satellite.isActive ? 1.5 : 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(satellite.help)
    }

    // MARK: Actions

    private func switchTo(_ newPage: IslandPage) {
        page = (page == newPage && newPage != .controls) ? .controls : newPage
    }

    private func openSettings() {
        island.collapse()
        NotificationCenter.default.post(name: .sweepOpenSettings, object: nil,
                                        userInfo: ["section": SettingsSection.island.rawValue])
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
            subtitle: String(localized: "Sweep and Clipboard, together at the top of your screen. Hidden until you move the mouse to the notch, then it slides out. Changes apply live.")
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
        case .clipboard: base = String(localized: "Your clipboard history.")
        }
        if !tileAvailable(tile) {
            return base + " " + String(localized: "(Enable the feature first.)")
        }
        return base
    }
}
