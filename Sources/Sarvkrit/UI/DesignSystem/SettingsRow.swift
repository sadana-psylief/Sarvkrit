import SwiftUI

/// The one row spec. Icon column, title + caption, trailing control column — fixed widths, fixed
/// height, used by every toggle in the dropdown.
///
/// The caption line is *always* laid out, even when empty. That's deliberate: a feature that
/// becomes blocked swaps its summary for "Needs Accessibility access", and without a reserved line
/// the row would change height mid-flight and shove everything below it. Reserving the space is
/// most of what removed the perceived jank.
struct SettingsRow<Trailing: View>: View {
    let symbolName: String
    let title: String
    var caption: String
    var captionColor: Color = .secondary
    var isHighlighted: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            FeatureIconTile(
                symbolName: symbolName,
                isOn: isHighlighted,
                size: Theme.Metrics.iconColumn
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(captionColor)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.sm)

            trailing
                .frame(width: Theme.Metrics.switchColumn, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.toggleRowHeight)
        .contentShape(Rectangle())
    }
}

/// A row that behaves like a menu item: full-width hover highlight, optional shortcut hint.
/// Replaces the blue `.buttonStyle(.link)` text that made the bottom of the panel look like a
/// web page rather than a menu.
struct MenuActionRow: View {
    let title: String
    var shortcut: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.sm) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Space.sm)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Metrics.rowInset)
            .frame(height: Theme.Metrics.menuRowHeight)
            .frame(maxWidth: .infinity)
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
    }
}
