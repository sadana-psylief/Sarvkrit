import SwiftUI

/// The monitor's menu bar item: the app's gauge icon and whichever readings the user chose.
///
/// **A `MenuBarExtra` label renders exactly one `Image` and one `Text`.** Everything beyond that is
/// dropped with no warning and no error — an `HStack` of per-segment symbol-and-number pairs shows
/// only its first pair, and building the readout as one concatenated `Text` with inline
/// `Text(Image(systemName:))` loses every image instead. Both were tried against the real menu bar.
/// So the readings arrive here pre-joined into a single string, and the only icon is this one.
/// If you are tempted to put a second `Image` or `Text` in here, that is why it will not appear.
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
            Text(feature.menuBarLine)
                .font(.system(size: 11, weight: .medium))
                // Proportional digits change the item's width on almost every sample, which shoves
                // every item to the left of this one along with it.
                .monospacedDigit()
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// The numbers convey nothing without their names, and the icon conveys nothing at all.
    private var accessibilityLabel: String {
        let line = feature.menuBarLine
        return line.isEmpty ? "Sarvkrit System Monitor" : "System Monitor: \(line)"
    }
}
