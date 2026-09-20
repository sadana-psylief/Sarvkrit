import XCTest
@testable import Sarvkrit

/// Where the event log is allowed to be written from.
///
/// **This suite exists because of a crash, and it is the third in this feature.**
///
/// ```
/// objc_opt_class → swift_getObjectType → swift_task_isMainExecutorImpl
///   → MainActor.assumeIsolated → closure #1 in EventRecorder.installMonitors()
///   → GlobalObserverHandler → DispatchEventToHandlers → … → NSApplicationMain
/// EXC_BAD_ACCESS, KERN_INVALID_ADDRESS at 0x000000000000001e
/// ```
///
/// The monitors were installed while `start()` was still blocked inside AVFoundation, which pumps
/// the run loop as it waits. AppKit delivered a click to the global monitor with a main-actor frame
/// still on the stack, `MainActor.assumeIsolated` asked the concurrency runtime which executor was
/// current, and the answer was the address `0x1e`.
///
/// `CameraRecorder` no longer blocks, so that window is closed — but the recorder should never have
/// been asserting its way onto an actor from an AppKit callback in the first place. AppKit makes no
/// isolation promise the compiler can see. `RecordingWriter` learned this after the first crash in
/// this same feature: *"the hot path must not touch the main actor."*
///
/// So the state is lock-guarded and the callbacks record where they land.
final class EventRecorderIsolationTests: XCTestCase {

    /// Every flag survives, from any thread, with no main actor anywhere in sight. Before this,
    /// `EventRecorder` was `@MainActor` and this did not compile — which is what red looks like
    /// for an isolation bug.
    func testFlagsRecordedFromManyThreadsAreAllKept() {
        let recorder = EventRecorder()
        recorder.begin(mapping: { _ in nil })

        let group = DispatchGroup()
        for _ in 0..<200 {
            DispatchQueue.global().async(group: group) { recorder.flag() }
        }
        group.wait()

        let log = recorder.finish(anchoredTo: 0)
        XCTAssertEqual(log.flags.count, 200, "a flag was lost between threads")
    }

    /// Beginning twice must not leave two sets of monitors installed. It used to, and then every
    /// click and keystroke was recorded twice — doubled click rings and a doubled keystroke
    /// overlay in the finished video.
    func testBeginningTwiceDoesNotDoubleTheMonitors() {
        let recorder = EventRecorder()
        recorder.begin(mapping: { _ in nil })
        recorder.begin(mapping: { _ in nil })

        XCTAssertEqual(recorder.installedMonitorCount, 1,
                       "a second begin() installed another monitor on top of the first")
    }

    /// A recording that never started still has to give its monitors back. `finish()` on the
    /// service is gated behind `isRecording`, so when a start failed part-way nothing removed
    /// them, and the app went on watching every click on the Mac for the rest of its life.
    func testFinishingWithoutAnAnchorStillRemovesTheMonitors() {
        let recorder = EventRecorder()
        recorder.begin(mapping: { _ in nil })
        XCTAssertEqual(recorder.installedMonitorCount, 1)

        _ = recorder.finish(anchoredTo: nil)

        XCTAssertEqual(recorder.installedMonitorCount, 0)
    }
}
