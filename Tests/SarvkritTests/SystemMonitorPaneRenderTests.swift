import SwiftUI
import XCTest
@testable import Sarvkrit

/// Renders the pane for real.
///
/// The charts are the app's first `import Charts`, and the data they are handed is the awkward
/// kind: windows containing gaps, a peak of zero on an idle machine, and a single sample before a
/// rate exists. Each of those is a plausible way to divide by nothing and hand a NaN to a chart
/// axis, which is not the sort of failure a unit test on the model would notice.
///
/// So this mounts the view and forces a layout pass. It asserts no visual detail — it proves the
/// pane builds, lays out and survives the data it will actually be given.
@MainActor
final class SystemMonitorPaneRenderTests: XCTestCase {

    private func hosted(_ feature: SystemMonitorFeature) -> NSView {
        let view = NSHostingView(
            rootView: SystemMonitorDetailView(feature: feature)
                .environmentObject(AppState.shared)
        )
        view.frame = CGRect(x: 0, y: 0, width: 720, height: 900)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testThePaneLaysOutWithNoReadingsAtAll() {
        // What the pane looks like in the instant after being switched on.
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "pane.\(UUID())")!)
        XCTAssertGreaterThan(hosted(feature).fittingSize.height, 0)
    }

    func testThePaneLaysOutWithGapsInEveryWindow() {
        // A window of nothing but gaps has a nil peak. If the chart's y-domain were built from it
        // without a floor, this is the layout that would produce 0...0 and NaN bar heights.
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "pane.\(UUID())")!)
        feature.activate()
        for _ in 0..<3 { feature.apply(SystemSnapshot()) }
        XCTAssertGreaterThan(hosted(feature).fittingSize.height, 0)
        feature.deactivate()
    }

    func testThePaneLaysOutWithAFullSpreadOfRealReadings() {
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "pane.\(UUID())")!)
        feature.activate()
        for step in 0..<40 {
            var snapshot = SystemSnapshot()
            snapshot.cpu = CPUSample(usage: Double(step % 100), coreCount: 10)
            snapshot.gpu = GPUSample(usage: 12)
            snapshot.memory = MemorySample(used: 9_878_424_780, total: 17_179_869_184)
            snapshot.disk = DiskSample(
                used: 412_000_000_000, total: 994_000_000_000,
                readPerSecond: 1_048_576, writePerSecond: 524_288)
            snapshot.network = NetworkSample(downloadPerSecond: 3_250_586, uploadPerSecond: 419_430)
            snapshot.battery = BatterySample(
                percent: 87, isCharging: false, isPresent: true,
                minutesRemaining: 134, cycleCount: 402)
            snapshot.power = PowerSample(source: .battery, watts: -8.4, adapterWatts: nil)
            // Every third sample is a gap, so the charts render a broken line rather than a
            // continuous one — the case `if let` inside the ForEach exists for.
            feature.apply(step % 3 == 0 ? SystemSnapshot() : snapshot)
        }
        XCTAssertGreaterThan(hosted(feature).fittingSize.height, 0)
        feature.deactivate()
    }

    // MARK: - The tray rows

    private func hostedTray(_ feature: SystemMonitorFeature) -> NSView {
        let view = NSHostingView(rootView: SystemMonitorTrayView(feature: feature))
        view.frame = CGRect(x: 0, y: 0, width: Theme.Size.dropdownWidth, height: 400)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testTheTrayRowsAreTheSameHeightWhicheverMetricsAreWatched() {
        // A MenuBarExtra panel is anchored under its icon once and never repositioned, so content
        // that changes height while open drags its top edge off the menu bar. That is only
        // observable by noticing the drift, which nobody does reliably — so it is pinned here.
        let all = SystemMonitorFeature(defaults: UserDefaults(suiteName: "tray.\(UUID())")!)
        let one = SystemMonitorFeature(defaults: UserDefaults(suiteName: "tray.\(UUID())")!)
        one.enabledMetrics = [.cpu]

        let allHeight = hostedTray(all).fittingSize.height
        XCTAssertGreaterThan(allHeight, 0)
        XCTAssertEqual(
            hostedTray(one).fittingSize.height, allHeight,
            "the panel must not change height as metrics are switched on and off"
        )
    }

    func testASwitchedOffMetricStillHasARowShowingAPlaceholder() {
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "tray.\(UUID())")!)
        feature.enabledMetrics = [.cpu]
        // Nothing to assert about pixels; this is the layout path for the mixed enabled/disabled
        // case, which is the one that would crash if `value(for:)` assumed a sample existed.
        XCTAssertGreaterThan(hostedTray(feature).fittingSize.height, 0)
    }
}
