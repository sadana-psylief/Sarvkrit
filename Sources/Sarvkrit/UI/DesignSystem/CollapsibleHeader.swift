import SwiftUI

/// A tappable section header that opens and closes what follows it.
///
/// Exists because `DisclosureGroup` inside a grouped `Form` renders its content but offers no
/// working toggle — the label isn't a button and the triangle has no usable hit region.
///
/// Three things here are load-bearing, each from a round of this control not working:
///
/// 1. **The explicit height.** A label with no height gives `contentShape` only the text line to
///    work with, inside a Form row that looks twice as tall, so clicks near the top and bottom fall
///    through. `MenuActionRow`, `SettingsRow` and `TrayTabBar` all size themselves before
///    `contentShape` for the same reason.
/// 2. **A tap gesture rather than a `Button`.** `.formStyle(.grouped)` is `NSTableView`-backed, and
///    a plain-styled button in that context wanted a click to establish the row before it would
///    activate — so collapsing took two clicks, the second only landing once the pointer had moved.
///    A gesture doesn't negotiate with that machinery. The accessibility a `Button` gives for free
///    is put back by hand below, because trading VoiceOver for a mouse fix would not be a fix.
/// 3. **A plain `Bool` and a closure, not a `Binding`.** The owner already holds the state; a
///    two-way binding rebuilt on every render only adds a question about identity.
///
/// Belongs in a `Section`'s `header:` slot, not among its rows — see `WindowDetailView`.
struct CollapsibleHeader: View {
    let title: String
    /// Right-aligned secondary text, e.g. "3 of 6".
    var caption: String?
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
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
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .standardMotion(value: isHovering)
        .clickableCursor()
        // Everything `Button` would have supplied, restored explicitly.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onToggle)
    }
}
