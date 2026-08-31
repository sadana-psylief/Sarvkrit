import SwiftUI

/// A tappable section header that opens and closes what follows it.
///
/// Exists because `DisclosureGroup` inside a grouped `Form` renders its content but offers no
/// working toggle — the label isn't a button and the triangle has no usable hit region. Rather
/// than a second attempt at that, this follows the pattern the rest of the app already uses when
/// macOS won't supply a usable control: an explicit `Button` with an explicit size.
///
/// **The size is the point.** A label with no height gives `contentShape` only the text line to
/// work with — roughly 17pt — inside a Form row that looks twice as tall, so clicks near the top
/// and bottom fall through and the control feels broken. `MenuActionRow`, `SettingsRow` and
/// `TrayTabBar` all set an explicit height before `contentShape` for exactly this reason.
struct CollapsibleHeader: View {
    let title: String
    /// Right-aligned secondary text, e.g. "3 of 6".
    var caption: String?
    @Binding var isExpanded: Bool

    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
                Spacer(minLength: Theme.Space.sm)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: Theme.Metrics.menuRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .standardMotion(value: isHovering)
        .clickableCursor()
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
    }

    private func toggle() {
        withAnimation(Theme.Motion.standard) { isExpanded.toggle() }
    }
}
