import SwiftUI

/// The row of icon-only tabs at the top of the menu bar panel.
///
/// Hand-built rather than a `TabView`: macOS's `TabView` brings full tab-view chrome — window-style
/// borders and its own content padding — which is wrong inside a popover. All this needs is a row
/// of equal-width buttons with a selection highlight.
///
/// The tabs used to carry a 10pt label under the glyph, which is why `Theme.Size.dropdownWidth`
/// grew four times chasing a width that fit the longest word. Dropping the label is what lets nine
/// panels sit in less room than eight labelled ones needed, and it is the one change here that
/// costs something: the name now exists only in the tooltip and in what VoiceOver reads. Both are
/// therefore required, not optional polish.
///
/// The selected tab uses the same accent tint at the same opacity as `FeatureIconTile`'s on-state,
/// so "selected" and "enabled" read as one visual language rather than two.
struct TrayPanelStrip: View {
    let panels: [TrayPanel]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(panels) { panel in
                TrayPanelTab(panel: panel, isSelected: panel.id == selection) {
                    selection = panel.id
                }
            }
        }
        .padding(Theme.Space.xs)
        // One container behind the whole strip, the way a segmented control reads as a single
        // control rather than a row of loose buttons.
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panels")
    }
}

private struct TrayPanelTab: View {
    let panel: TrayPanel
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            Image(systemName: panel.symbolName)
                .font(.system(size: Theme.Metrics.tabIcon, weight: .medium))
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
                )
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metrics.tabSquare)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.tabRadius, style: .continuous)
                        .fill(background)
                )
                // The stroke, not just the fill, is what separates the selected tab from a merely
                // hovered one at a glance — a fill alone left the two nearly indistinguishable in
                // light mode, where both land close to the panel's own background.
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.tabRadius, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.5) : .clear,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .standardMotion(value: isSelected)
        .standardMotion(value: isHovering)
        .clickableCursor()
        // With the label gone these two are the only places the panel's name exists. A tooltip for
        // the pointer, the accessibility label for VoiceOver — and the trait, because an icon
        // alone conveys neither that this is a tab nor that it is the current one.
        .help(panel.title)
        .accessibilityLabel(panel.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.15)) }
        if isHovering { return AnyShapeStyle(Color.secondary.opacity(0.12)) }
        return AnyShapeStyle(Color.clear)
    }
}
