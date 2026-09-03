import SwiftUI

/// The monitor's menu bar item: an icon and whichever numbers the user chose.
///
/// Holds the feature as an `@ObservedObject` **directly**, for the reason `MenuBarLabel` spells
/// out — SwiftUI does not observe through a nested `ObservableObject`, so a readout routed via
/// `AppState` would update only on some unrelated redraw. It needs no timer of its own: the feature
/// publishes every sample, which is the whole point of doing the sampling there.
struct SystemMonitorMenuBarLabel: View {
    @ObservedObject var feature: SystemMonitorFeature

    var body: some View {
        HStack(spacing: 4) {
            // Template-rendered, like every other icon in this menu bar: a coloured glyph would
            // stop inverting on light and dark bars and stop dimming when the bar is inactive.
            Image(systemName: feature.symbolName)
            ForEach(feature.menuBarSegments) { segment in
                HStack(spacing: 2) {
                    Image(systemName: segment.symbolName)
                    // Monospaced digits: proportional ones change the item's width on almost every
                    // sample, which shoves every item to the left of this one along with it.
                    Text(segment.text)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// The icons convey nothing without this, and the numbers convey nothing without their names.
    private var accessibilityLabel: String {
        let readings = zip(feature.menuBarMetrics, feature.menuBarSegments)
            .map { "\($0.title) \($1.text)" }
            .joined(separator: ", ")
        return readings.isEmpty ? "Sarvkrit System Monitor" : "System Monitor: \(readings)"
    }
}
