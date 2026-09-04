import SwiftUI

/// A brightness slider per connected display.
struct DisplaysPanelView: View {
    @ObservedObject var feature: DisplaysFeature

    var body: some View {
        SettingsModule {
            if feature.displays.isEmpty {
                FootnoteRow(text: "No displays found", symbolName: "display")
            } else {
                ForEach(Array(feature.displays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 { ModuleSeparator() }
                    row(for: display)
                }
            }
        }
    }

    private func row(for display: ConnectedDisplay) -> some View {
        let channel = feature.channel(for: display)
        let level = feature.levels[display.id]

        return HStack(spacing: Theme.Space.md) {
            FeatureIconTile(
                symbolName: display.isBuiltIn ? "laptopcomputer" : "display",
                isOn: (level ?? 0) > 0.5)

            VStack(alignment: .leading, spacing: 1) {
                Text(display.name)
                    .font(.system(size: Theme.Typography.body))
                    .lineLimit(1)
                Text(level.map { "\(Int(($0 * 100).rounded()))%" } ?? MetricFormatting.placeholder)
                    .font(.system(size: Theme.Typography.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)

            if let level, channel != .unavailable {
                Slider(
                    value: Binding(
                        get: { Double(level) },
                        set: { feature.setBrightness(Float($0), for: display) }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.toggleRowHeight)
        .overlay(alignment: .bottomLeading) { explanation(channel) }
    }

    /// Says when the slider is dimming the picture rather than moving a backlight.
    ///
    /// The one thing this panel must not do is imply it can brighten a display past the setting on
    /// the monitor itself. A gamma slider that runs to 100% and stops there is honest; one that
    /// looks identical to a real brightness control is not.
    @ViewBuilder
    private func explanation(_ channel: BrightnessChannel) -> some View {
        if let text = channel.explanation {
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.leading, Theme.Metrics.rowInset + Theme.Size.iconTile + Theme.Space.md)
                .padding(.bottom, 2)
        }
    }
}
