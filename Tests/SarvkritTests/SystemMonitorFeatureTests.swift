import Combine
import XCTest
@testable import Sarvkrit

/// The feature's contract with the rest of the app.
///
/// Three of these encode promises the app makes everywhere and would break silently here. Nothing
/// may sample until the feature is switched on; switching it off must stop every timer at once; and
/// a same-value write to a bound setting must notify nobody, because that loop is what once pinned
/// a core at 100% (see `AppState`'s note on hand-rolled setters).
final class SystemMonitorFeatureTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    private func makeFeature() -> SystemMonitorFeature {
        SystemMonitorFeature(defaults: UserDefaults(suiteName: "monitor.\(UUID())")!)
    }

    private func countNotifications(
        from feature: SystemMonitorFeature, during body: () -> Void
    ) -> Int {
        var count = 0
        feature.objectWillChange.sink { _ in count += 1 }.store(in: &cancellables)
        body()
        return count
    }

    // MARK: - Nothing runs until it is switched on

    func testConstructionStartsNothing() {
        // `FeatureRegistry.makeAll()` builds every feature on launch, including the ones the user
        // has switched off. A timer started in init would sample forever regardless of the toggle.
        let feature = makeFeature()
        XCTAssertFalse(feature.isRunning)
        XCTAssertEqual(feature.reading.snapshot, SystemSnapshot())
        XCTAssertTrue(feature.reading.history.isEmpty)
    }

    func testDeactivateStopsRunningAndDiscardsEverything() {
        let feature = makeFeature()
        MainActor.assumeIsolated {
            feature.activate()
            XCTAssertTrue(feature.isRunning)
            feature.deactivate()
        }
        XCTAssertFalse(feature.isRunning)
        XCTAssertEqual(feature.reading.snapshot, SystemSnapshot(),
                       "a switched-off monitor must not keep showing its last reading")
        XCTAssertTrue(feature.reading.history.isEmpty, "history is in-memory only, and off means off")
    }

    func testActivateThenDeactivateIsRepeatableWithoutAccumulatingTimers() {
        // `AppState.sync()` calls these in pairs on every toggle. A timer left behind on each
        // cycle would multiply the sampling rate invisibly.
        let feature = makeFeature()
        MainActor.assumeIsolated {
            for _ in 0..<5 {
                feature.activate()
                feature.deactivate()
            }
        }
        XCTAssertFalse(feature.isRunning)
    }

    // MARK: - The feature contract

    func testRequiresNoPermissions() {
        // Reading counters is not touching input. Inheriting the protocol default would gate the
        // monitor behind the Accessibility grant and break FeatureCategoryTests as well.
        XCTAssertTrue(makeFeature().requirements.isEmpty)
        XCTAssertFalse(makeFeature().requiresAccessibility)
    }

    func testIsNotAnEventTapFeature() {
        XCTAssertFalse(makeFeature() is EventTapFeature)
    }

    func testIdentityIsStable() {
        // This string is the UserDefaults key for the toggle. Renaming it resets the user's choice.
        XCTAssertEqual(makeFeature().id, "system-monitor")
        XCTAssertEqual(makeFeature().category, .system)
    }

    // MARK: - Settings

    func testEveryMetricIsWatchedByDefault() {
        // Someone switching on "System Monitor" means all of it; opting out is the per-metric job.
        XCTAssertEqual(makeFeature().enabledMetrics, Set(MetricKind.allCases))
    }

    func testSettingsSurviveARestart() {
        let defaults = UserDefaults(suiteName: "monitor.\(UUID())")!
        let first = SystemMonitorFeature(defaults: defaults)
        first.enabledMetrics = [.cpu, .memory]
        first.interval = .fiveSeconds

        let second = SystemMonitorFeature(defaults: defaults)
        XCTAssertEqual(second.enabledMetrics, [.cpu, .memory])
        XCTAssertEqual(second.interval, .fiveSeconds)
    }

    func testAnUnknownPersistedMetricIsDroppedRatherThanCrashing() {
        // A downgrade, or a metric removed in a later release, must not take the pane with it.
        let defaults = UserDefaults(suiteName: "monitor.\(UUID())")!
        defaults.set(["cpu", "flux-capacitor"], forKey: "systemMonitor.enabledMetrics")
        XCTAssertEqual(SystemMonitorFeature(defaults: defaults).enabledMetrics, [.cpu])
    }

    func testWritingTheSameSettingValueNotifiesNobody() {
        // The render loop this project has already been bitten by: SwiftUI writes back through
        // two-way bindings as an ordinary part of an update pass.
        let feature = makeFeature()
        let metrics = feature.enabledMetrics
        let interval = feature.interval
        let menuBar = feature.menuBarMetrics

        let notifications = countNotifications(from: feature) {
            feature.enabledMetrics = metrics
            feature.interval = interval
            feature.menuBarMetrics = menuBar
        }
        XCTAssertEqual(notifications, 0, "same-value writes must be genuinely inert")
    }

    func testChangingASettingNotifiesOnce() {
        let feature = makeFeature()
        XCTAssertEqual(countNotifications(from: feature) { feature.interval = .oneSecond }, 1)
    }

    func testChangingTheIntervalDiscardsHistory() {
        // A window holding both 1-second and 5-second samples misrepresents its own x-axis: the
        // sparkline would show two minutes of history in a span that covers ten.
        let feature = makeFeature()
        MainActor.assumeIsolated {
            feature.apply(SystemSnapshot(cpu: CPUSample(usage: 42, coreCount: 10)))
            XCTAssertFalse(feature.reading.history.isEmpty, "precondition: something was recorded")
            feature.interval = .fiveSeconds
            XCTAssertTrue(feature.reading.history.isEmpty)
        }
    }

    func testSwitchingAMetricOffDiscardsItsHistory() {
        // Its row disappears from the pane; leaving the samples behind would make switching it
        // back on show a jump from stale data rather than a fresh line.
        let feature = makeFeature()
        MainActor.assumeIsolated {
            feature.apply(SystemSnapshot(cpu: CPUSample(usage: 42, coreCount: 10)))
            XCTAssertNotNil(feature.reading.history[.cpu], "precondition")
            feature.enabledMetrics = feature.enabledMetrics.subtracting([.cpu])
            XCTAssertNil(feature.reading.history[.cpu])
        }
    }

    // MARK: - Sampling honours the per-metric switches

    func testADisabledMetricIsNotSampled() {
        // The app's core promise, at metric granularity: nothing runs that you switched off.
        let feature = makeFeature()
        feature.enabledMetrics = [.memory]
        MainActor.assumeIsolated {
            let sampled = feature.takeSnapshot()
            XCTAssertNotNil(sampled.memory, "the one enabled metric should have been read")
            XCTAssertNil(sampled.cpu)
            XCTAssertNil(sampled.gpu)
            XCTAssertNil(sampled.disk)
            XCTAssertNil(sampled.network)
            XCTAssertNil(sampled.battery)
            XCTAssertNil(sampled.power)
        }
    }

    func testSamplingWithEverythingEnabledFillsTheSnapshot() {
        let feature = makeFeature()
        MainActor.assumeIsolated {
            let sampled = feature.takeSnapshot()
            // Rates need two readings, so they are legitimately nil on the first; the absolute
            // readings are not, and a nil here means a sampler silently failed.
            XCTAssertNotNil(sampled.cpu)
            XCTAssertNotNil(sampled.memory)
            XCTAssertNotNil(sampled.disk)
            XCTAssertNotNil(sampled.power)
        }
    }

    // MARK: - Live data in the menu bar

    func testLiveDataInTheMenuBarIsOnByDefault() {
        // Switching the monitor on at all is already the signal that someone wants to see it; the
        // per-metric picker is what trims how much of it shows.
        XCTAssertTrue(makeFeature().showsLiveDataInMenuBar)
    }

    func testTheMenuBarLineIsEmptyWhenLiveDataIsOff() {
        // Empty rather than nil, and `MenuBarIconState.trailingText` treats it as absent — so
        // Keep Awake's countdown keeps the slot to itself with no dangling separator.
        let feature = makeFeature()
        MainActor.assumeIsolated {
            feature.activate()
            feature.apply(SystemSnapshot(cpu: CPUSample(usage: 42, coreCount: 10)))
            XCTAssertFalse(feature.menuBarLine.isEmpty, "precondition: something to show")
            feature.showsLiveDataInMenuBar = false
            XCTAssertEqual(feature.menuBarLine, "")
            feature.deactivate()
        }
    }

    func testSwitchingLiveDataOffDoesNotStopSampling() {
        // The readings are still shown in the Sarvkrit menu; only the menu bar text goes away.
        let feature = makeFeature()
        MainActor.assumeIsolated {
            feature.activate()
            feature.showsLiveDataInMenuBar = false
            XCTAssertTrue(feature.isRunning)
            feature.apply(SystemSnapshot(cpu: CPUSample(usage: 42, coreCount: 10)))
            XCTAssertNotNil(feature.reading.snapshot.cpu, "sampling must continue")
            feature.deactivate()
        }
    }

    func testTheLiveDataSettingSurvivesARestart() {
        let defaults = UserDefaults(suiteName: "monitor.\(UUID())")!
        SystemMonitorFeature(defaults: defaults).showsLiveDataInMenuBar = false
        XCTAssertFalse(SystemMonitorFeature(defaults: defaults).showsLiveDataInMenuBar)
    }

    func testWritingTheSameLiveDataValueNotifiesNobody() {
        let feature = makeFeature()
        let current = feature.showsLiveDataInMenuBar
        XCTAssertEqual(
            countNotifications(from: feature) { feature.showsLiveDataInMenuBar = current }, 0)
    }

    func testOnlyOneMetricShowsInTheMenuBarByDefault() {
        // The readout shares the app's own icon rather than owning a status item, so the default is
        // one number. "5m \u{00B7} CPU 16% \u{00B7} MEM 66%" beside an icon nobody asked to grow is a lot of
        // menu bar to take by default.
        XCTAssertEqual(makeFeature().menuBarMetrics, [.cpu])
    }

    // MARK: - The readings appear in the Sarvkrit menu

    func testTheFeatureSuppliesTrayContent() {
        // `MenuBarView` builds the strip from these. Returning none is how the readings would
        // quietly lose their tab with every other test still passing.
        MainActor.assumeIsolated {
            let panels = makeFeature().trayPanels()
            XCTAssertEqual(panels.map(\.id), ["system", "network", "disks", "power"])
            // Order is the strip's order, so this pins it: Network before Disks before Power is
            // what the tabs read left to right.
            XCTAssertTrue(panels.allSatisfy { !$0.title.isEmpty && !$0.symbolName.isEmpty })
        }
    }

    func testASwitchedOffMonitorContributesNothingToTheMenuBar() {
        // The bug this pins shipped for one commit and was visible only in the real menu bar: with
        // the feature switched off the label still read "CPU —", because the line was gated on the
        // live-data preference alone. A feature that is off must say nothing at all — a placeholder
        // implies a reading that is merely unavailable, and the app's promise is that nothing runs.
        let feature = makeFeature()
        XCTAssertEqual(feature.menuBarLine, "", "a monitor that was never switched on says nothing")

        MainActor.assumeIsolated {
            feature.activate()
            feature.apply(SystemSnapshot(cpu: CPUSample(usage: 42, coreCount: 10)))
            XCTAssertFalse(feature.menuBarLine.isEmpty, "precondition: it speaks while running")
            feature.deactivate()
            XCTAssertEqual(feature.menuBarLine, "", "switching it off must clear the menu bar too")
        }
    }
}
