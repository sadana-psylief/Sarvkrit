import SwiftUI

/// Every reading, shown under the feature's row in the Sarvkrit menu.
///
/// This is where the full set lives. The monitor adds no status item of its own — Sarvkrit is one
/// menu bar icon — so the text beside that icon is only ever a summary, and this is the place you
/// come to see everything.
///
/// A sibling row type inside the caller's `SettingsModule`, like `VolumeMixerTrayView`: it supplies
/// no padding, width or background of its own, and keeps `Theme.Metrics.rowInset` so the module's
/// hairlines stay aligned with the toggle rows above it.
struct SystemMonitorTrayView: View {
    @ObservedObject var feature: SystemMonitorFeature

    var body: some View {
        VStack(spacing: 0) {
            ModuleSeparator()
            // Every metric, always — including the ones switched off.
            //
            // A MenuBarExtra panel is positioned by the system once, anchored under the icon, so
            // content that changes height while it is open drags the panel's top edge away from the
            // menu bar. Rendering only the enabled metrics would do exactly that each time one was
            // toggled. Seven fixed rows make the height constant, and "—" against a switched-off
            // metric says honestly that it isn't being read rather than implying it read nothing.
            ForEach(MetricKind.allCases) { kind in
                row(for: kind)
            }
        }
    }

    private func row(for kind: MetricKind) -> some View {
        let isWatched = feature.enabledMetrics.contains(kind)
        return HStack(spacing: Theme.Space.md) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(isWatched ? .secondary : .tertiary)
                .frame(width: Theme.Metrics.iconColumn, alignment: .center)
            Text(kind.title)
                .font(.system(size: 12))
                .foregroundStyle(isWatched ? .primary : .tertiary)
            Spacer()
            Text(value(for: kind, isWatched: isWatched))
                .font(.system(size: 12, weight: .medium))
                // The house style for a number that changes: monospaced digits, so a row doesn't
                // twitch as its value moves.
                .monospacedDigit()
                .foregroundStyle(isWatched ? .primary : .tertiary)
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.menuRowHeight)
        .accessibilityElement(children: .combine)
    }

    private func value(for kind: MetricKind, isWatched: Bool) -> String {
        guard isWatched else { return MetricFormatting.placeholder }
        return MenuBarReadout.segments(for: feature.reading.snapshot, metrics: [kind])
            .first?.text ?? MetricFormatting.placeholder
    }
}
