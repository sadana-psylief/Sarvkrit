import XCTest
@testable import Sarvkrit

/// How the playhead moves while a project is playing.
///
/// **This suite exists because the editor never played anything.** Two faults met here.
///
/// The clock that drives playback is a display link taken from `NSScreen.main` — the screen holding
/// the *key window*. `StudioPlayer` is built by `StudioEditorController.open` before its window
/// exists, in an accessory app that frequently has no key window at all, so the link was nil, and
/// `tick()` never ran once. That is not just a still playhead: `tick()` is also the only thing that
/// decodes a frame, so `FrameSources.screen` stayed nil and the editor composited a background over
/// nothing.
///
/// And the arithmetic inside `tick()` assumed every tick was exactly 1/60 of a second, then forced a
/// keyframe-exact seek on every one of them — sixty a second, on top of the real-time playback that
/// setting `rate` had already started.
///
/// Both halves are pure arithmetic once separated from AVFoundation, which is what this pins.
final class PlaybackClockTests: XCTestCase {

    /// The bug, stated directly: a tick that is not 1/60 of a second must advance the playhead by
    /// what actually elapsed. On a 120 Hz display the old arithmetic ran at double speed; on a
    /// stalled frame it lost time outright.
    func testThePlayheadAdvancesByRealElapsedTime() {
        let step = PlaybackClock.advance(playhead: 1.0, elapsed: 1.0 / 120.0, rate: 1,
                                         duration: 10)
        XCTAssertEqual(step.playhead, 1.0 + 1.0 / 120.0, accuracy: 1e-9)
        XCTAssertFalse(step.reachedEnd)
    }

    func testRateMultipliesElapsedTime() {
        let doubled = PlaybackClock.advance(playhead: 0, elapsed: 0.5, rate: 2, duration: 10)
        XCTAssertEqual(doubled.playhead, 1.0, accuracy: 1e-9)
    }

    /// J/K/L shuttles backwards with a negative rate, and reaching zero is an end too.
    func testPlayingBackwardsStopsAtTheStart() {
        let step = PlaybackClock.advance(playhead: 0.2, elapsed: 0.5, rate: -1, duration: 10)
        XCTAssertEqual(step.playhead, 0, accuracy: 1e-9)
        XCTAssertTrue(step.reachedEnd)
    }

    func testReachingTheEndClampsAndStops() {
        let step = PlaybackClock.advance(playhead: 9.9, elapsed: 0.5, rate: 1, duration: 10)
        XCTAssertEqual(step.playhead, 10, accuracy: 1e-9)
        XCTAssertTrue(step.reachedEnd)
    }

    /// **The seek storm.** Output time and source time diverge only where the project cuts, so the
    /// player needs nudging back into place there and nowhere else. Asking for a keyframe-exact
    /// seek on every tick is what no decoder could service.
    func testNoResyncWhenThePlayerIsAlreadyWhereItShouldBe() {
        XCTAssertFalse(PlaybackClock.needsResync(playerTime: 4.001, wanted: 4.0, tolerance: 0.05))
    }

    func testResyncAcrossACut() {
        XCTAssertTrue(PlaybackClock.needsResync(playerTime: 4.0, wanted: 9.0, tolerance: 0.05))
    }

    func testResyncAfterDriftingPastTheTolerance() {
        XCTAssertTrue(PlaybackClock.needsResync(playerTime: 4.0, wanted: 4.2, tolerance: 0.05))
    }
}

/// The clock itself, over a real file.
final class StudioPlayerClockTests: XCTestCase {

    /// **The test host has no key window, which is exactly the failing condition.** `NSScreen.main`
    /// is nil here for the same reason it was nil when the editor opened, so a player that only
    /// asks `NSScreen.main` gets no display link and never ticks again.
    @MainActor
    func testAPlayerGetsAClockEvenWithNoKeyWindow() {
        XCTAssertNil(NSApplication.shared.keyWindow,
                     "precondition: this suite is meaningful only without a key window")

        let player = StudioPlayer(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-recording.mov"))

        XCTAssertTrue(player.isTicking,
                      "no display link, so tick() never runs: no playhead, no redraw, no decoded frame")
    }
}

/// Where a moment in the recording lands inside `camera.mov`.
///
/// **The two tracks do not start together.** The capture graph takes time to come up, so in a real
/// take here the screen ran 29.175 s and the camera 26.747 s — the camera began 2.43 s late. Drawing
/// it at the screen's own time would put the picture two and a half seconds ahead of the action,
/// against a standard this feature already sets for the cursor: *"getting it wrong by 80 ms puts the
/// pointer visibly behind what it clicked."*
final class CameraTrackTimeTests: XCTestCase {

    private let offset: TimeInterval = 2.43
    private let cameraDuration: TimeInterval = 26.747

    func testTheCameraIsBehindTheScreenByItsStartOffset() {
        let t = PlaybackClock.cameraTime(forSource: 10, startOffset: offset,
                                         cameraDuration: cameraDuration)
        XCTAssertEqual(try XCTUnwrap(t), 7.57, accuracy: 1e-9)
    }

    /// Before the camera existed there is no frame to draw, and that is not an error — `drawCamera`
    /// already draws nothing for a nil image.
    func testThereIsNoCameraBeforeItStarted() {
        XCTAssertNil(PlaybackClock.cameraTime(forSource: 1.0, startOffset: offset,
                                              cameraDuration: cameraDuration))
    }

    /// The whole take is covered once the offset is applied: a camera that started 2.43 s late and
    /// ran 26.747 s reaches 29.177 s, which is the screen's 29.175 s. Both tracks stopped together;
    /// only the start differed. Getting this wrong in the first draft of this test is why it is
    /// spelled out.
    func testTheOffsetCoversTheWholeTakeWhenBothTracksStoppedTogether() {
        XCTAssertNotNil(PlaybackClock.cameraTime(forSource: 29.1, startOffset: offset,
                                                 cameraDuration: cameraDuration))
    }

    /// A camera that genuinely stopped early — the file output failing part-way, which has happened
    /// — leaves the tail with no picture, and that is not an error.
    func testThereIsNoCameraAfterItEnded() {
        XCTAssertNil(PlaybackClock.cameraTime(forSource: 29.1, startOffset: offset,
                                              cameraDuration: 20))
    }

    /// An older bundle records no offset at all, so zero must behave exactly as before.
    func testAZeroOffsetMapsStraightThrough() {
        let t = PlaybackClock.cameraTime(forSource: 5, startOffset: 0, cameraDuration: 30)
        XCTAssertEqual(try XCTUnwrap(t), 5, accuracy: 1e-9)
    }
}
