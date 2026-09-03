import SwiftUI

/// "<Grant> needed", shown in the dropdown and the detail pane.
///
/// It appears above the feature toggles, which go disabled at the same time. That pairing is
/// the most important UX detail in the app: a toggle that can be flipped but silently does
/// nothing is worse than one that's greyed out with a reason attached.
///
/// The text comes from the `Requirement` rather than being written here, so a second grant can't
/// end up with a banner that says "Accessibility" — which is exactly what this view used to do,
/// back when Accessibility was the only thing it could be about.
struct PermissionBanner: View {
    let requirement: Requirement
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("\(requirement.title) needed")
                    .font(.subheadline.weight(.semibold))
                Text(requirement.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .accessibilityElement(children: .contain)
    }
}
