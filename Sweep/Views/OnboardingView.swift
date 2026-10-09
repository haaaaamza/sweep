import SwiftUI
import AppKit

/// First-launch onboarding (Phase 6): what it is → enable your first
/// feature → set the shortcut. Shown once.
struct OnboardingView: View {
    let onFinish: () -> Void
    @ObservedObject var registry = FeatureRegistry.shared
    @State private var page = 0

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcomePage
                case 1: featuresPage
                default: shortcutPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(page == pageCount - 1 ? String(localized: "Done") : String(localized: "Continue")) {
                    if page == pageCount - 1 {
                        onFinish()
                    } else {
                        page += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: 420)
    }

    // MARK: Page 1 — what it is

    private var welcomePage: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Sweep")
                .font(.title.weight(.semibold))
            Text("One click hides your messy desktop — every file icon and every open app disappear. A second click brings everything back exactly as it was.\n\nSweep lives in your menu bar, and everything runs locally: no network, no accounts, no analytics.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Page 2 — enable your first feature

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enable your first feature")
                .font(.title2.weight(.semibold))
            Text("Everything in Sweep is off until you turn it on. Start with the signature pair:")
                .font(.callout)
                .foregroundStyle(.secondary)

            onboardingToggle(DesktopSweepModule.shared)
            onboardingToggle(AppSweepModule.shared)

            Text("Clipboard History lives in Settings → Features.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onboardingToggle(_ module: FeatureModule) -> some View {
        Toggle(isOn: Binding(
            get: { registry.isEnabled(module.id) },
            set: { registry.setEnabled(module.id, $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name)
                Text(module.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Page 3 — set the shortcut

    private var shortcutPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Set your Sweep shortcut")
                .font(.title2.weight(.semibold))
            Text("One press sweeps everything away, a second press restores it — from anywhere, no clicking required.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ShortcutRecorderView()
            Text("You can change this later in Settings → General.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

final class OnboardingWindowController: NSWindowController {
    convenience init(onFinish: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Sweep")
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(onFinish: onFinish))
        window.center()
        self.init(window: window)
    }
}
