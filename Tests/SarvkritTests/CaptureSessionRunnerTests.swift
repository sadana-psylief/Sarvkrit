import XCTest
@testable import Sarvkrit

/// Ordering inside a capture graph.
///
/// **This suite exists because of a crash, and it is the second of its kind.**
/// `AVCaptureSession.startRunning()` blocks until the graph is up, and anything that needs a
/// running session — `AVCaptureMovieFileOutput.startRecording(to:)` — blocks until it is.
/// `CameraRecorder` issued the first on a detached task and the second on the main actor, so the
/// main thread sat inside AVFoundation waiting on work that had been handed to another thread.
/// AVFoundation pumps the run loop while it waits, so a click reached a global event monitor with
/// a main-actor frame still on the stack and the app died in the concurrency runtime's executor
/// check, reading address `0x1e`.
///
/// The rule this suite pins is the one that was missing: **every call into a capture graph goes
/// through one serial queue, in the order it was asked for, and never on the calling thread.**
final class CaptureSessionRunnerTests: XCTestCase {

    /// Collects call names from whichever thread runs them.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func record(_ name: String) {
            lock.lock(); names.append(name); lock.unlock()
        }

        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }; return names
        }
    }

    /// The whole bug in one assertion: a slow first call must still finish before the second
    /// starts. `startRunning()` is the slow one, and `startRecording(to:)` is what used to
    /// overtake it.
    func testLaterWorkWaitsForSlowerEarlierWork() {
        let runner = CaptureSessionRunner(label: "test-order")
        let log = Log()
        let done = expectation(description: "all three ran")
        done.expectedFulfillmentCount = 3

        runner.submit {
            Thread.sleep(forTimeInterval: 0.2)
            log.record("startRunning")
            done.fulfill()
        }
        runner.submit { log.record("startRecording"); done.fulfill() }
        runner.submit { log.record("stopRecording"); done.fulfill() }

        wait(for: [done], timeout: 5)
        XCTAssertEqual(log.recorded, ["startRunning", "startRecording", "stopRecording"])
    }

    /// A stop asked for in the same breath as a start must still land second, rather than running
    /// against a session that has not come up yet — which is how the preview left the camera on
    /// with nothing holding a reference to switch it off.
    func testStopAskedForImmediatelyAfterStartStillRunsSecond() {
        let runner = CaptureSessionRunner(label: "test-stop-after-start")
        let log = Log()
        let done = expectation(description: "both ran")
        done.expectedFulfillmentCount = 2

        runner.submit {
            Thread.sleep(forTimeInterval: 0.15)
            log.record("start")
            done.fulfill()
        }
        runner.submit { log.record("stop"); done.fulfill() }

        wait(for: [done], timeout: 5)
        XCTAssertEqual(log.recorded, ["start", "stop"])
    }

    /// Nothing the graph does may happen on the main thread. This is the property that keeps the
    /// main actor out of AVFoundation's blocking calls, and it is the one that was missing.
    func testWorkNeverRunsOnTheMainThread() {
        let runner = CaptureSessionRunner(label: "test-off-main")
        let done = expectation(description: "ran")
        let onMain = Log()

        runner.submit {
            if Thread.isMainThread { onMain.record("main") }
            done.fulfill()
        }

        wait(for: [done], timeout: 2)
        XCTAssertEqual(onMain.recorded, [], "graph calls must never run on the main thread")
    }
}
