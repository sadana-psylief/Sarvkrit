import XCTest
@testable import Sarvkrit

/// When the recording pill gets out of the way.
///
/// **It sits over the thing being demonstrated.** A panel at full strength in the middle of a
/// screen recording is in every frame of the finished video, so it fades back once the recording
/// is under way — and comes straight back when the pointer arrives, because stopping must never
/// involve a hunt.
final class RecordingHUDDimmingTests: XCTestCase {

    func testItIsFullyVisibleWhenItAppears() {
        XCTAssertEqual(HUDDimming.opacity(sinceWake: 0), 1)
    }

    func testItStaysUpLongEnoughToBeRead() {
        XCTAssertEqual(HUDDimming.opacity(sinceWake: HUDDimming.wakeSeconds - 0.1), 1)
    }

    func testItFadesBackOnceTheRecordingIsUnderWay() {
        XCTAssertEqual(HUDDimming.opacity(sinceWake: HUDDimming.wakeSeconds + 1),
                       HUDDimming.restingOpacity)
    }

    /// The pointer arriving is the whole way back. Anything else would mean hunting for the stop
    /// button on a panel you can barely see.
    func testHoveringWakesIt() {
        XCTAssertEqual(HUDDimming.opacity(sinceWake: 60, isHovered: true), 1)
    }

    /// **A paused recording must not look like a running one, or like nothing at all.** This is
    /// the state where somebody has stepped away and needs to find their way back.
    func testAPausedRecordingStaysVisible() {
        XCTAssertEqual(HUDDimming.opacity(sinceWake: 60, isPaused: true), 1)
    }

    /// A warning that fades out is not a warning. Dropped frames mean the file is stuttering, and
    /// producing that in silence is the failure the counter exists to prevent.
    func testDroppedFramesKeepItVisible() {
        XCTAssertEqual(HUDDimming.opacity(sinceWake: 60, isWarning: true), 1)
    }

    /// Never invisible. A pill nobody can find is the same as no pill, and there would then be no
    /// way to stop a recording except a shortcut you may not remember.
    func testItNeverDisappearsCompletely() {
        XCTAssertGreaterThan(HUDDimming.restingOpacity, 0.2)
    }
}
