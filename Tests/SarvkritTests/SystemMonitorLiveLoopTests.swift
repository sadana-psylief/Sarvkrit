import Combine
import XCTest
@testable import Sarvkrit

/// The whole loop, running for real: timer fires, samplers read the hardware, the reading is
/// published on main, the history grows, and the menu bar readout renders actual numbers.
///
/// Every other test here covers one link. This is the one that would have caught the two failures
/// this project has hit before — a layer that compiled, looked right, and did nothing — because it
/// asserts that a *second* sample produces a rate, which is the first moment any of the baseline
/// and generation machinery is actually exercised.
final class SystemMonitorLiveLoopTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func testSamplingProducesRealReadingsAndThenStopsCompletely() {
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "live.\(UUID())")!)
        feature.interval = .oneSecond

        let settled = expectation(description: "two CPU samples recorded")
        // The loop keeps ticking after the condition is first met; that is the point, not an error.
        settled.assertForOverFulfill = false

        MainActor.assumeIsolated {
            feature.objectWillChange
                .sink { _ in
                    // objectWillChange fires *before* the value lands, so look on the next turn.
                    DispatchQueue.main.async {
                        if (feature.reading.history[.cpu]?.samples.count ?? 0) >= 2 {
                            settled.fulfill()
                        }
                    }
                }
                .store(in: &cancellables)
            feature.activate()
        }

        wait(for: [settled], timeout: 15)

        MainActor.assumeIsolated {
            let reading = feature.reading

            // A rate needs two readings. That the second one produced a number is what proves the
            // baseline was carried across ticks on the sampling queue rather than reset each time.
            XCTAssertNotNil(reading.snapshot.cpu?.usage,
                            "a second sample must yield a CPU usage — the baseline wasn't kept")
            XCTAssertNotNil(reading.snapshot.memory, "memory was never read")
            XCTAssertGreaterThanOrEqual(reading.history[.cpu]?.samples.count ?? 0, 2)

            // The readout the user actually sees, not just the model behind it.
            let segments = MenuBarReadout.segments(for: reading.snapshot, metrics: [.cpu, .memory])
            XCTAssertEqual(segments.count, 2)
            for segment in segments {
                XCTAssertNotEqual(segment.text, MetricFormatting.placeholder,
                                  "the menu bar is still showing a placeholder after two samples")
            }

            // And off means off, from a genuinely running state rather than a never-started one.
            feature.deactivate()
            XCTAssertFalse(feature.isRunning)
            XCTAssertEqual(feature.reading, MonitorReading())
        }
    }

    func testNothingIsPublishedAfterDeactivation() {
        // The generation guard, exercised against the real timer: a sample already in flight when
        // the feature is switched off must not land afterwards and repopulate what was just
        // cleared, leaving the pane showing live data for a feature that is off.
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "live.\(UUID())")!)
        feature.interval = .oneSecond

        MainActor.assumeIsolated {
            feature.activate()
            // Stop it immediately — mid-flight is exactly the window being tested.
            feature.deactivate()
        }

        let quiet = expectation(description: "stays cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { quiet.fulfill() }
        wait(for: [quiet], timeout: 10)

        MainActor.assumeIsolated {
            XCTAssertEqual(feature.reading, MonitorReading(),
                           "a late sample repopulated a switched-off monitor")
            XCTAssertFalse(feature.isRunning)
        }
    }
}
