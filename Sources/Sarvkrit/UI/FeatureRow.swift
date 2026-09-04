import SwiftUI

/// A feature's toggle, expressed in the shared row spec so it aligns with every other row by
/// construction rather than by matching paddings.
struct FeatureRow: View {
    let feature: any Feature
    @Binding var isOn: Bool
    var isBlocked: Bool
    /// Which permission is missing, in the user's words.
    ///
    /// Passed in rather than derived: this row used to say "Needs Accessibility access" whatever
    /// was actually missing, which sent people to the wrong settings pane the moment a second
    /// grant existed.
    var blockedReason: String?

    var body: some View {
        SettingsRow(
            symbolName: feature.symbolName,
            title: feature.title,
            caption: isBlocked ? (blockedReason ?? "Needs a permission") : feature.summary,
            captionColor: isBlocked ? .orange : .secondary,
            isHighlighted: isOn && !isBlocked
        ) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isBlocked)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feature.title)
        .accessibilityHint(isBlocked ? (blockedReason ?? "Needs a permission") : feature.summary)
    }
}
