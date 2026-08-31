import SwiftUI

/// Icon-over-label tabs for the dropdown.
///
/// Hand-built rather than a `TabView`: macOS's `TabView` brings full tab-view chrome — window-style
/// borders and its own content padding — which is wrong inside a 320pt popover. All this needs is a
/// row of equal-width buttons with a selection highlight.
///
/// The selected tab uses the same accent tint at the same opacity as `FeatureIconTile`'s on-state,
/// so "selected" and "enabled" read as one visual language rather than two.
struct TrayTabBar: View {
    let tabs: [TrayTab]
    @Binding var selection: TrayTab

    var body: some View {
        // 8pt, not the 2 it started at: with six tabs the selection and hover fills nearly
        // touched. The dropdown was widened to 360 at the same time, because more gap inside the
        // old 320 would only have made each tab narrower.
        HStack(spacing: Theme.Space.sm) {
            ForEach(tabs) { tab in
                TrayTabButton(tab: tab, isSelected: tab == selection) {
                    selection = tab
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Categories")
    }
}

private struct TrayTabButton: View {
    let tab: TrayTab
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: Theme.Metrics.tabIcon, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.tabHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.tabRadius, style: .continuous)
                    .fill(background)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .standardMotion(value: isSelected)
        .standardMotion(value: isHovering)
        .clickableCursor()
        // The 10pt labels can scale down to fit, so the full name stays available on hover.
        .help(tab.title)
        // VoiceOver needs to hear that this is a tab and whether it's the current one; an icon and
        // a 10pt label alone don't convey that.
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.15)) }
        if isHovering { return AnyShapeStyle(Color.secondary.opacity(0.12)) }
        return AnyShapeStyle(Color.clear)
    }
}
