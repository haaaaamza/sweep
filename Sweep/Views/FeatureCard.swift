import SwiftUI

/// Shared chrome for the selected feature's card in the menu bar panel.
/// Feature switching happens in the panel's icon tab strip; the card just
/// shows the feature's name, live status and controls.
struct FeatureCard<Content: View>: View {
    let id: String
    let title: String
    let systemImage: String
    /// Shows a small dot in the header while something is running (a swept
    /// state, an awake session).
    var isActive: Bool = false
    /// Short trailing status readout (a count, a countdown, a CPU readout).
    var detail: String?
    @ViewBuilder var content: Content

    init(id: String,
         title: String,
         systemImage: String,
         isActive: Bool = false,
         detail: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isActive = isActive
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
