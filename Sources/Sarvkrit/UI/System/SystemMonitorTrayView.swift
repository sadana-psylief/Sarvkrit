import SwiftUI

/// The panel behind the monitor's menu bar item: every enabled reading at once.
///
/// Fixed height on purpose. A `MenuBarExtra` window is positioned once by the system and anchored
/// under its icon, so content that changes height while open drags the panel's top edge away from
/// the menu bar — and these rows appear and disappear as readings become available.
struct SystemMonitorTrayView: View {
    @ObservedObject var feature: SystemMonitorFeature

    private var metrics: [MetricKind] {
        MetricKind.allCases.filter { feature.enabledMetrics.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("System Monitor")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    MainWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityLabel("Open System Monitor settings")
            }
            .padding(.horizontal, Theme.Space.xs)

            SettingsModule {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, kind in
                    if index > 0 { ModuleSeparator() }
                    row(for: kind)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .frame(width: Theme.Size.dropdownWidth, height: Self.panelHeight)
    }

    /// Sized for all seven readings, so the panel does not resize as metrics are switched on and
    /// off — see the note above about anchored panels.
    private static let panelHeight: CGFloat = 300

    private func row(for kind: MetricKind) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Theme.Metrics.iconColumn, alignment: .center)
            Text(kind.title)
                .font(.system(size: 12))
            Spacer()
            Text(MenuBarReadout.segments(for: feature.reading.snapshot, metrics: [kind]).first?.text
                 ?? MetricFormatting.placeholder)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.menuRowHeight)
    }
}
