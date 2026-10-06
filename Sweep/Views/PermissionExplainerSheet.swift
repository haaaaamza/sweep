import SwiftUI
import AppKit

/// FR-7.1: shown BEFORE a feature that needs a permission is enabled,
/// explaining exactly why, with a deep link to the right System Settings pane.
/// (No v1 feature currently requires a permission — this flow is wired and
/// ready for modules that declare `requiredPermissions`.)
struct PermissionExplainerSheet: View {
    let featureName: String
    let permissions: [PermissionKind]
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("\(featureName) needs your permission", systemImage: "lock.shield")
                .font(.headline)

            ForEach(permissions, id: \.self) { permission in
                VStack(alignment: .leading, spacing: 4) {
                    Text(permission.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(permission.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings…") {
                        NSWorkspace.shared.open(permission.settingsDeepLink)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Enable Feature", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

enum PermissionExplainers {
    /// Permissions the module declares that are NOT currently granted.
    static func pendingKinds(for module: FeatureModule) -> [PermissionKind] {
        module.requiredPermissions.filter { !$0.isGranted }
    }
}
