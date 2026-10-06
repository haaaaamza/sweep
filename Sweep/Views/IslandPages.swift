import SwiftUI
import AppKit
import IOKit.ps

// MARK: - Controls (home) page

/// The hub's landing page: a wide Now Playing card beside a Volume card, over a
/// row of quick-action tiles. Mirrors the reference "Controls" screen.
struct ControlsHomePage: View {
    @ObservedObject var registry: FeatureRegistry
    let onOpenPage: (IslandPage) -> Void

    @ObservedObject var nowPlaying = NowPlayingModule.shared
    @ObservedObject var audio = SystemAudioModule.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                nowPlayingCard
                    .frame(maxWidth: .infinity)
                volumeCard
                    .frame(width: 190)
            }
            quickTiles
            Spacer(minLength: 0)
        }
    }

    // MARK: Now Playing card

    private var nowPlayingCard: some View {
        HStack(spacing: 11) {
            artwork
            if let info = nowPlaying.info {
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(info.artist ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    transport
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing playing")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Your music and playback controls appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .islandCard()
        .contentShape(Rectangle())
        .onTapGesture { onOpenPage(.nowPlaying) }
    }

    private var artwork: some View {
        Group {
            if let art = nowPlaying.info?.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.secondary))
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button { nowPlaying.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 12))
            }.buttonStyle(.plain)
            Button { nowPlaying.togglePlayPause() } label: {
                Image(systemName: (nowPlaying.info?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
            }.buttonStyle(.plain)
            Button { nowPlaying.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 12))
            }.buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.top, 2)
    }

    // MARK: Volume card

    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: audio.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Volume")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(audio.masterVolume * 100))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            IslandSlider(value: Binding(
                get: { audio.masterVolume },
                set: { audio.setMasterVolume($0) }))
            HStack(spacing: 4) {
                Text(audio.outputDeviceName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .islandCard()
    }

    // MARK: Quick tiles

    private var quickTiles: some View {
        HStack(spacing: 10) {
            quickTile(.volumeMixer, icon: "speaker.wave.2.fill", label: String(localized: "Volume mixer"))
            quickTile(.keepAwake, icon: "moon.zzz.fill", label: String(localized: "Keep awake"))
            quickTile(.timer, icon: "timer", label: String(localized: "Timer"))
            quickTile(.calendar, icon: "calendar", label: String(localized: "Calendar"))
        }
    }

    private func quickTile(_ page: IslandPage, icon: String, label: String) -> some View {
        Button { onOpenPage(page) } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(height: 22)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick access grid

/// One tile per page with its shortcut; a check on the active one.
struct IslandGridPage: View {
    @ObservedObject var registry: FeatureRegistry
    let onOpenPage: (IslandPage) -> Void
    let onOpenSettings: () -> Void
    let onOpenMonitor: () -> Void

    @ObservedObject var prefs = IslandPrefs.shared

    private var pages: [IslandPage] {
        var result: [IslandPage] = [.controls, .volumeMixer, .nowPlaying, .system, .calendar,
                                    .notifications, .timer, .downloads, .aiAgents]
        // Honor Quick-access grid visibility toggles (controls is always shown).
        result = result.filter { page in
            if page == .controls { return true }
            guard let tile = IslandTile.allCases.first(where: { $0.page == page }) else { return true }
            return prefs.showsTile(tile)
        }
        return result
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5),
                      spacing: 10) {
                ForEach(pages) { page in
                    tile(page)
                }
            }
            .padding(.top, 2)
        }
    }

    private func tile(_ page: IslandPage) -> some View {
        Button { onOpenPage(page) } label: {
            VStack(spacing: 7) {
                Image(systemName: page.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(page.accent)
                    .frame(height: 24)
                Text(page.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(page.shortcutDisplay ?? " ")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(page.title)
    }
}

// MARK: - Volume mixer page

struct VolumeMixerPage: View {
    @ObservedObject var audio = SystemAudioModule.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(audio.outputDeviceName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    // Master channel.
                    channel(icon: audio.masterMuted ? "speaker.slash.fill" : "speaker.fill",
                            iconImage: nil,
                            value: Binding(get: { audio.masterVolume },
                                           set: { audio.setMasterVolume($0) }),
                            percent: Int(audio.masterVolume * 100),
                            muted: audio.masterMuted) {
                        audio.toggleMasterMute()
                    }

                    ForEach(audio.apps) { app in
                        channel(icon: "app.fill",
                                iconImage: app.icon,
                                value: Binding(
                                    get: { app.muted ? 0 : app.gain },
                                    set: { audio.setGain($0, for: app.id) }),
                                percent: Int((app.muted ? 0 : app.gain) * 100),
                                muted: app.muted) {
                            audio.toggleMute(for: app.id)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .onAppear { audio.start() }
    }

    private func channel(icon: String, iconImage: NSImage?, value: Binding<Double>,
                         percent: Int, muted: Bool, onToggleMute: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: onToggleMute) {
                Group {
                    if let iconImage {
                        Image(nsImage: iconImage).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(muted ? Color.secondary : Color.white)
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            VerticalSlider(value: value, tint: muted ? .gray : .white)
                .frame(height: 120)
            Text("\(percent)%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: 46)
    }
}

// MARK: - Now Playing page

struct NowPlayingPage: View {
    @ObservedObject var module = NowPlayingModule.shared

    var body: some View {
        Group {
            if let info = module.info {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        Group {
                            if let art = info.artwork {
                                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.white.opacity(0.08))
                                    .overlay(Image(systemName: "music.note")
                                        .font(.system(size: 28)).foregroundStyle(.secondary))
                            }
                        }
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 5) {
                            Text(info.title)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white).lineLimit(2)
                            if let artist = info.artist {
                                Text(artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let album = info.album {
                                Text(album).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }

                    if let duration = info.duration, duration > 0 {
                        IslandProgressBar(fraction: (info.elapsed ?? 0) / duration, tint: .white)
                    }

                    HStack(spacing: 34) {
                        Button { module.previousTrack() } label: {
                            Image(systemName: "backward.fill").font(.system(size: 20))
                        }.buttonStyle(.plain)
                        Button { module.togglePlayPause() } label: {
                            Image(systemName: info.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 42))
                        }.buttonStyle(.plain)
                        Button { module.nextTrack() } label: {
                            Image(systemName: "forward.fill").font(.system(size: 20))
                        }.buttonStyle(.plain)
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.top, 6)
            } else {
                islandEmptyState(icon: "music.note",
                                 title: String(localized: "Nothing playing"),
                                 caption: module.isAvailable
                                    ? String(localized: "Start playing audio and it shows up here.")
                                    : String(localized: "Live now-playing isn't available on this version of macOS."))
            }
        }
        .onAppear { if module.isAvailable { module.start() } }
    }
}

// MARK: - System page

struct SystemPage: View {
    let onOpenNetwork: () -> Void
    let onOpenMonitor: () -> Void

    @ObservedObject var glance = SystemGlanceModule.shared
    @StateObject private var network = NetworkMonitor()
    @State private var battery = BatteryReader.read()

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 10) {
                statCard(icon: "cpu", title: String(localized: "CPU"),
                         value: glance.stats?.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "…",
                         fraction: (glance.stats?.cpuPercent ?? 0) / 100)
                statCard(icon: "display", title: String(localized: "GPU"),
                         value: "—", fraction: nil)
                statCard(icon: "memorychip", title: String(localized: "Memory"),
                         value: memoryPercentText, fraction: memoryFraction)

                statCard(icon: "battery.100", title: String(localized: "Battery"),
                         value: battery.map { "\($0.percent)%" } ?? "—",
                         fraction: battery.map { Double($0.percent) / 100 },
                         wide: true)
                networkCard
                    .gridCellColumns(1)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                statCard(icon: "internaldrive", title: String(localized: "Available"),
                         value: glance.stats?.diskFreeBytes.map(SystemGlanceCard.formatBytes) ?? "…",
                         fraction: nil)
                statCard(icon: "bolt.fill", title: String(localized: "Power"),
                         value: battery?.powerSource ?? "—", fraction: nil)
            }
            .padding(.top, 10)
        }
        .onAppear { network.start(); battery = BatteryReader.read() }
        .onDisappear { network.stop() }
    }

    private var memoryPercentText: String {
        guard let stats = glance.stats, let used = stats.memoryUsedBytes, stats.memoryTotalBytes > 0 else { return "…" }
        return String(format: "%.0f%%", Double(used) / Double(stats.memoryTotalBytes) * 100)
    }
    private var memoryFraction: Double? {
        guard let stats = glance.stats, let used = stats.memoryUsedBytes, stats.memoryTotalBytes > 0 else { return nil }
        return Double(used) / Double(stats.memoryTotalBytes)
    }

    private func statCard(icon: String, title: String, value: String,
                          fraction: Double?, wide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let fraction {
                IslandProgressBar(fraction: fraction, tint: .orange)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var networkCard: some View {
        Button(action: onOpenNetwork) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "globe").font(.system(size: 10, weight: .semibold))
                    Text("Network").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                Text("↓ \(NetworkMonitor.formatRate(network.downloadRate))")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Text("↑ \(NetworkMonitor.formatRate(network.uploadRate))")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Network page

struct NetworkPage: View {
    @StateObject private var monitor = NetworkMonitor()

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("↓ \(NetworkMonitor.formatRate(monitor.downloadRate))")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                    Text("↑ \(NetworkMonitor.formatRate(monitor.uploadRate))")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.blue)
                    Spacer()
                }
                NetworkChart(samples: monitor.history)
                    .frame(height: 96)
            }
            .islandCard()

            VStack(spacing: 0) {
                statRow(String(localized: "Download"), NetworkMonitor.formatRate(monitor.downloadRate))
                Divider().overlay(.white.opacity(0.08))
                statRow(String(localized: "Upload"), NetworkMonitor.formatRate(monitor.uploadRate))
                Divider().overlay(.white.opacity(0.08))
                statRow(String(localized: "This session"),
                        "↓\(NetworkMonitor.formatBytes(monitor.sessionDownBytes))  ↑\(NetworkMonitor.formatBytes(monitor.sessionUpBytes))")
            }
            .islandCard(padding: 4)
            Spacer(minLength: 0)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

/// A two-line throughput chart (download green, upload blue).
struct NetworkChart: View {
    let samples: [NetworkMonitor.Sample]

    var body: some View {
        GeometryReader { geo in
            let maxRate = max(samples.map { max($0.downBytesPerSec, $0.upBytesPerSec) }.max() ?? 1, 1)
            ZStack {
                line(for: \.downBytesPerSec, in: geo.size, max: maxRate).stroke(.green, lineWidth: 2)
                line(for: \.upBytesPerSec, in: geo.size, max: maxRate).stroke(.blue, lineWidth: 2)
            }
        }
    }

    private func line(for key: KeyPath<NetworkMonitor.Sample, Double>, in size: CGSize, max maxRate: Double) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        let stepX = size.width / CGFloat(samples.count - 1)
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * stepX
            let y = size.height - CGFloat(sample[keyPath: key] / maxRate) * size.height
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// MARK: - Calendar page

struct CalendarPage: View {
    @ObservedObject var module = CalendarModule.shared

    var body: some View {
        Group {
            switch module.access {
            case .granted:
                if module.events.isEmpty {
                    islandEmptyState(icon: "calendar",
                                     title: String(localized: "No upcoming events"),
                                     caption: String(localized: "You're all clear for the next week."))
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) {
                            ForEach(module.events) { event in eventRow(event) }
                        }
                    }
                }
            case .denied:
                islandEmptyState(icon: "calendar.badge.exclamationmark",
                                 title: String(localized: "Calendar access off"),
                                 caption: String(localized: "Allow calendar access in System Settings to see events."),
                                 actionLabel: String(localized: "Open System Settings…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .notDetermined:
                islandPermissionState(icon: "calendar",
                                      caption: String(localized: "Read your calendars to show upcoming appointments. Events stay on this Mac."),
                                      actionLabel: String(localized: "Allow Calendar Access")) {
                    module.requestAccess()
                }
            }
        }
        .onAppear { module.refreshAccess() }
    }

    private func eventRow(_ event: CalendarModule.Event) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(event.calendarColor)).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let location = event.location, !location.isEmpty {
                    Text(location).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(CalendarModule.relativeTime(for: event))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Notifications page

struct NotificationsPage: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(.orange)
                Text("Accessibility").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text(trusted ? String(localized: "Granted") : String(localized: "Not granted"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(trusted ? .green : .orange)
            }
            if !trusted {
                HStack(spacing: 8) {
                    Button {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                    } label: {
                        pillLabel(String(localized: "Grant access"), filled: true)
                    }.buttonStyle(.plain)
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        pillLabel(String(localized: "Open System Settings…"), filled: false)
                    }.buttonStyle(.plain)
                }
            }
            Text("Show new visible banners only. Messages stay in memory and are cleared when you lock this Mac or turn this off.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .onAppear { trusted = AXIsProcessTrusted() }
    }

    private func pillLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: filled ? .bold : .semibold))
            .foregroundStyle(filled ? .black : .white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - Timer page

struct TimerPage: View {
    @ObservedObject var module = TimerModule.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ForEach(TimerModule.Mode.allCases) { mode in
                    tab(mode.label, selected: module.mode == mode) { module.mode = mode }
                }
                Spacer()
                Button(action: startStopAction) {
                    Text(startStopLabel)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(Color.orange.opacity(0.22), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            switch module.mode {
            case .timer: timerBody
            case .pomodoro: pomodoroBody
            case .stopwatch: stopwatchBody
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var timerBody: some View {
        HStack(alignment: .center, spacing: 14) {
            TickDial(values: Array(stride(from: 5, through: 60, by: 5)),
                     labeledValues: [5, 15, 30, 45, 60],
                     selection: Binding(get: { module.selectedMinutes },
                                        set: { module.setMinutes($0) }),
                     disabled: module.isTimerRunning)
            Text(TimerModule.format(module.timerRemaining))
                .font(.system(size: 30, weight: .medium).monospacedDigit())
                .foregroundStyle(.orange.opacity(module.isTimerRunning ? 1 : 0.8))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(width: 110, alignment: .trailing)
        }
        .frame(maxHeight: .infinity)
    }

    private var pomodoroBody: some View {
        VStack(spacing: 10) {
            Text(module.pomodoroPhase.label.uppercased())
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.orange).tracking(1)
            Text(TimerModule.format(module.pomodoroRemaining))
                .font(.system(size: 44, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            Text(String(localized: "\(module.completedPomodoros) completed today"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stopwatchBody: some View {
        HStack {
            Spacer()
            Text(TimerModule.formatStopwatch(module.stopwatchElapsed))
                .font(.system(size: 46, weight: .medium).monospacedDigit()).foregroundStyle(.white)
            Spacer()
            if module.stopwatchElapsed > 0 {
                Button { module.resetStopwatch() } label: {
                    Text("Reset").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var startStopLabel: String {
        switch module.mode {
        case .timer: return module.isTimerRunning ? String(localized: "Stop") : String(localized: "Start")
        case .pomodoro: return module.isPomodoroRunning ? String(localized: "Stop") : String(localized: "Start")
        case .stopwatch: return module.isStopwatchRunning ? String(localized: "Pause") : String(localized: "Start")
        }
    }

    private func startStopAction() {
        switch module.mode {
        case .timer: module.isTimerRunning ? module.stopTimer() : module.startTimer()
        case .pomodoro: module.isPomodoroRunning ? module.stopPomodoro() : module.startPomodoro()
        case .stopwatch: module.isStopwatchRunning ? module.pauseStopwatch() : module.startStopwatch()
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(selected ? .white : .secondary)
                Capsule().fill(selected ? Color.orange : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
    }
}

// MARK: - Downloads page

struct DownloadsPage: View {
    @ObservedObject var module = DownloadsModule.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $module.isEnabled) {
                    Text("Downloads").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button { module.chooseFolder() } label: {
                    Text("Choose Folder…")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.white.opacity(0.1), in: Capsule())
                }.buttonStyle(.plain)
            }
            Text("Choose the folder where your browser saves downloads. Only that folder is watched.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            if module.items.isEmpty {
                Spacer()
                Text(module.isEnabled ? String(localized: "Nothing downloaded yet.")
                                      : String(localized: "Turn on Downloads to watch a folder."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(module.items) { item in row(item) }
                    }
                }
            }
        }
    }

    private func row(_ item: DownloadsModule.Item) -> some View {
        Button { module.reveal(item) } label: {
            HStack(spacing: 9) {
                Image(nsImage: item.icon).resizable().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(DownloadsModule.formatBytes(item.size)) · \(item.date.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain)
    }
}

// MARK: - AI Agents page

struct AIAgentsPage: View {
    @ObservedObject var module = AIAgentsModule.shared

    var body: some View {
        Group {
            if !module.isAvailable {
                islandEmptyState(icon: "sparkles",
                                 title: String(localized: "No agent activity"),
                                 caption: String(localized: "Claude Code usage shows up here once you've run it on this Mac."))
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            claudeCard
                            spendingCard
                        }
                        nowCard
                    }
                }
            }
        }
        .onAppear { module.start(); module.refresh() }
        .onDisappear { module.stop() }
    }

    private var claudeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                Text("Claude").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text(module.lastActivity != nil ? String(localized: "Active") : String(localized: "Idle"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(AIAgentsModule.formatCost(module.estimatedCost))
                    .font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(.white)
            }
            IslandProgressBar(fraction: min(module.estimatedCost / 50, 1), tint: .orange)
            Text(AIAgentsModule.formatTokens(module.today.totalTokens) + String(localized: " tokens"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .islandCard()
    }

    private var spendingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("Spending").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Text("Today").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(AIAgentsModule.formatCost(module.estimatedCost))
                    .font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                Text("API value").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("\(AIAgentsModule.formatTokens(module.today.totalTokens)) tokens · \(Int(module.today.cacheFraction * 100))% from cache")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .islandCard()
    }

    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                Text("Now").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if let last = module.lastActivity {
                    Text(AIAgentsModule.relativeTime(last)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if module.recent.isEmpty {
                Text("No activity today.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(module.recent) { agent in
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(.orange)
                        Text(agent.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Spacer()
                        Text(AIAgentsModule.relativeTime(agent.lastActive))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            HourlyCostChart(values: module.hourlyCost).frame(height: 54).padding(.top, 2)
        }
        .islandCard()
    }
}

/// A 24-bar hourly cost chart.
struct HourlyCostChart: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 1, 0.0001)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(value > 0 ? Color.orange : Color.white.opacity(0.1))
                        .frame(height: max(3, geo.size.height * CGFloat(value / maxValue)))
                }
            }
        }
    }
}

// MARK: - Keep Awake page (unchanged behavior)

struct IslandKeepAwakePage: View {
    @ObservedObject var module = KeepAwakeModule.shared

    private let dialOptions: [KeepAwakeModule.Duration] = [
        .fifteenMinutes, .thirtyMinutes, .oneHour, .twoHours,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                tab(String(localized: "Timed"), selected: module.selectedDuration != .indefinite) {
                    guard !module.isSessionActive else { return }
                    if module.selectedDuration == .indefinite { module.selectedDuration = .fifteenMinutes }
                }
                tab(String(localized: "Indefinite"), selected: module.selectedDuration == .indefinite) {
                    guard !module.isSessionActive else { return }
                    module.selectedDuration = .indefinite
                }
                Spacer()
                Button {
                    module.isSessionActive ? module.stopSession() : module.startSession()
                } label: {
                    Text(module.isSessionActive ? String(localized: "Stop") : String(localized: "Start"))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.orange)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(Color.orange.opacity(0.22), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: 14) {
                if module.selectedDuration == .indefinite {
                    indefiniteDial
                } else {
                    TickDial(values: Array(stride(from: 5, through: 130, by: 5)),
                             labeledValues: [15, 30, 60, 120],
                             selection: Binding(
                                get: { module.selectedDuration.rawValue },
                                set: { module.selectedDuration = nearestDuration($0) }),
                             disabled: module.isSessionActive,
                             labelFor: { $0 >= 60 ? "\($0/60)h" : "\($0)" })
                }
                Text(readout)
                    .font(.system(size: 30, weight: .medium).monospacedDigit())
                    .foregroundStyle(.orange.opacity(module.isSessionActive ? 1 : 0.8))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: 96, alignment: .trailing)
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                optionChip(String(localized: "Display can sleep"),
                           isOn: Binding(get: { module.allowDisplaySleep }, set: { module.allowDisplaySleep = $0 }))
                optionChip(String(localized: "Stop below \(module.batteryCutoffPercent)% battery"),
                           isOn: Binding(get: { module.batteryCutoffEnabled }, set: { module.batteryCutoffEnabled = $0 }))
                Spacer()
            }
        }
        .padding(.top, 4)
    }

    private func nearestDuration(_ minutes: Int) -> KeepAwakeModule.Duration {
        dialOptions.min { abs($0.rawValue - minutes) < abs($1.rawValue - minutes) } ?? .fifteenMinutes
    }

    private var readout: String {
        if module.isSessionActive {
            guard let remaining = module.remaining else { return "∞" }
            return KeepAwakeCard.format(remaining)
        }
        switch module.selectedDuration {
        case .indefinite: return "∞"
        case .fifteenMinutes: return "15:00"
        case .thirtyMinutes: return "30:00"
        case .oneHour: return "1:00:00"
        case .twoHours: return "2:00:00"
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(selected ? .white : .secondary)
                Capsule().fill(selected ? Color.orange : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).fixedSize()
    }

    private var indefiniteDial: some View {
        HStack(spacing: 4) {
            ForEach(0..<24, id: \.self) { _ in
                Capsule().fill(Color.orange.opacity(module.isSessionActive ? 0.8 : 0.3))
                    .frame(width: 4, height: 26)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func optionChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle").font(.system(size: 10))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(isOn.wrappedValue ? Color.orange : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.white.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}

// MARK: - Clipboard page (unchanged behavior)

struct IslandClipboardPage: View {
    let onCollapse: () -> Void

    @ObservedObject var module = ClipboardModule.shared
    @ObservedObject var hotkeys = HotkeyManager.shared
    @State private var pickedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(countText).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCollapse()
                    ClipboardBezelController.shared.showOrAdvance()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "rectangle.stack").font(.system(size: 10, weight: .semibold))
                        Text(bezelLabel).font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
                if !module.clippings.isEmpty {
                    Button { module.clearHistory() } label: {
                        Text("Clear").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.white.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }

            if module.clippings.isEmpty {
                islandEmptyState(icon: "doc.on.clipboard",
                                 title: String(localized: "Nothing copied yet"),
                                 caption: String(localized: "Everything you copy appears here."))
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(module.clippings.prefix(6))) { clipping in row(clipping) }
                    }
                }
            }
        }
    }

    private var countText: String {
        let count = module.clippings.count
        return count == 1 ? String(localized: "1 clipping") : String(localized: "\(count) clippings")
    }

    private var bezelLabel: String {
        if let display = hotkeys.shortcut(for: .clipboard)?.display {
            return String(localized: "Bezel \(display)")
        }
        return String(localized: "Open bezel")
    }

    private func row(_ clipping: Clipping) -> some View {
        Button {
            module.pick(clipping)
            pickedID = clipping.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if pickedID == clipping.id { pickedID = nil }
            }
        } label: {
            HStack(spacing: 9) {
                thumbnail(clipping)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clipping.preview).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(subtitle(clipping)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: pickedID == clipping.id ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(pickedID == clipping.id ? Color.orange : .secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(_ clipping: Clipping) -> some View {
        if clipping.kind == .image, let image = module.image(for: clipping) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: clipping.kind == .image ? "photo" : "text.alignleft")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func subtitle(_ clipping: Clipping) -> String {
        var parts: [String] = []
        if let app = clipping.sourceApp { parts.append(app) }
        parts.append(clipping.date.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shared page components

/// Vertical fill slider for the volume mixer.
struct VerticalSlider: View {
    @Binding var value: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(tint.opacity(0.9))
                    .frame(height: max(0, h * CGFloat(min(max(value, 0), 1))))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    value = 1 - min(max(g.location.y / h, 0), 1)
                })
        }
        .frame(width: 30)
    }
}

/// Horizontal fill slider (volume card / scrubber).
struct IslandSlider: View {
    @Binding var value: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(tint)
                    .frame(width: max(0, w * CGFloat(min(max(value, 0), 1))))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    value = min(max(g.location.x / w, 0), 1)
                })
        }
        .frame(height: 6)
    }
}

/// Orange tick dial with labels and a triangle marker (Timer / Keep Awake).
struct TickDial: View {
    let values: [Int]
    let labeledValues: [Int]
    @Binding var selection: Int
    var disabled: Bool = false
    var labelFor: (Int) -> String = { "\($0)" }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ForEach(labeledValues, id: \.self) { value in
                    Text(labelFor(value))
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(value == selection ? Color.orange : Color.orange.opacity(0.4))
                        .position(x: x(for: value, width: width), y: 7)
                }
                ForEach(values, id: \.self) { value in
                    Capsule()
                        .fill(value <= selection ? Color.orange.opacity(0.9) : Color.orange.opacity(0.18))
                        .frame(width: 4, height: 24)
                        .position(x: x(for: value, width: width), y: 32)
                }
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .position(x: x(for: selection, width: width), y: 52)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    guard !disabled else { return }
                    selection = nearest(toX: g.location.x, width: width)
                })
        }
        .frame(height: 58)
        .opacity(disabled ? 0.55 : 1)
    }

    private func x(for value: Int, width: CGFloat) -> CGFloat {
        let lo = values.first ?? 0
        let hi = values.last ?? 1
        let span = CGFloat(max(hi - lo, 1))
        let fraction = CGFloat(value - lo) / span
        return 6 + fraction * (width - 12)
    }

    private func nearest(toX locationX: CGFloat, width: CGFloat) -> Int {
        values.min { abs(x(for: $0, width: width) - locationX) < abs(x(for: $1, width: width) - locationX) } ?? selection
    }
}

/// Battery snapshot via IOKit power sources.
enum BatteryReader {
    struct Snapshot { let percent: Int; let powerSource: String }

    static func read() -> Snapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return nil }
        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let percent = max > 0 ? Int(Double(current) / Double(max) * 100) : current
        let powerSource = state == kIOPSACPowerValue
            ? String(localized: "AC Power") : String(localized: "Battery")
        return Snapshot(percent: percent, powerSource: powerSource)
    }
}

// MARK: - Shared empty/permission states

@ViewBuilder
func islandEmptyState(icon: String, title: String, caption: String,
                      actionLabel: String? = nil, action: (() -> Void)? = nil) -> some View {
    VStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white.opacity(0.07)).frame(width: 64, height: 64)
            .overlay(Image(systemName: icon).font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary))
        Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
        Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        if let actionLabel, let action {
            Button(action: action) {
                Text(actionLabel).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.buttonStyle(.plain).padding(.top, 2)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

@ViewBuilder
func islandPermissionState(icon: String, caption: String,
                           actionLabel: String, action: @escaping () -> Void) -> some View {
    VStack(spacing: 12) {
        Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary)
        Text(caption).font(.system(size: 13)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        Button(action: action) {
            Text(actionLabel).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }.buttonStyle(.plain)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 20)
}
