import SwiftUI

/// A feature's toggle, expressed in the shared row spec so it aligns with every other row by
/// construction rather than by matching paddings.
struct FeatureRow: View {
    let feature: any Feature
    @Binding var isOn: Bool
    var isBlocked: Bool

    var body: some View {
        SettingsRow(
            symbolName: feature.symbolName,
            title: feature.title,
            caption: isBlocked ? "Needs Accessibility access" : feature.summary,
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
        .accessibilityHint(isBlocked ? "Needs Accessibility access" : feature.summary)
    }
}
