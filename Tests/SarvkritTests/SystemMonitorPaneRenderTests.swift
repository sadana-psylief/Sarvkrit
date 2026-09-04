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

    // MARK: - The menu bar panels

    private func hostedPanel(_ view: some View) -> NSView {
        let hosted = NSHostingView(rootView: view)
        hosted.frame = CGRect(x: 0, y: 0, width: Theme.Size.dropdownWidth, height: 400)
        hosted.layoutSubtreeIfNeeded()
        return hosted
    }

    func testEveryPanelLaysOutWhicheverMetricsAreWatched() {
        // This used to assert the tray content was the *same height* whatever was switched on,
        // because a `MenuBarExtra` panel is anchored under its icon once and content that changed
        // height while open dragged its top edge off the menu bar. `MenuBarWindowAnchor` resizes
        // the panel on every height change now, and the strip's panels differ in height by
        // hundreds of points anyway — so equal height is neither achievable nor needed, and what
        // is left worth pinning is that every combination lays out at all.
        for metrics in [Set(MetricKind.allCases), [.cpu], []] as [Set<MetricKind>] {
            let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "panel.\(UUID())")!)
            feature.enabledMetrics = metrics
            for view in [
                AnyView(SystemPanelView(feature: feature)),
                AnyView(NetworkPanelView(feature: feature)),
                AnyView(DisksPanelView(feature: feature)),
                AnyView(PowerPanelView(feature: feature)),
            ] {
                XCTAssertGreaterThan(hostedPanel(view).fittingSize.height, 0,
                                     "metrics: \(metrics)")
            }
        }
    }

    func testASwitchedOffMetricStillHasARowShowingAPlaceholder() {
        // The mixed enabled/disabled case is the one that would crash if a panel assumed a sample
        // existed for everything it draws.
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "panel.\(UUID())")!)
        feature.enabledMetrics = [.cpu]
        XCTAssertGreaterThan(hostedPanel(SystemPanelView(feature: feature)).fittingSize.height, 0)
        XCTAssertGreaterThan(hostedPanel(PowerPanelView(feature: feature)).fittingSize.height, 0)
    }
}
