import AVFoundation
import CoreMedia
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

    /// **Playing forward from a standstill must not immediately stop.** The first tick has no
    /// previous tick to measure against, so its elapsed time is zero — and a naive "at or before
    /// zero means we reached the start" check fires on the very first tick of every playback,
    /// pausing before anything moves. Found by the end-to-end play test, which is exactly what it
    /// is for.
    func testPlayingForwardFromTheStartDoesNotImmediatelyStop() {
        let first = PlaybackClock.advance(playhead: 0, elapsed: 0, rate: 1, duration: 10)
        XCTAssertEqual(first.playhead, 0)
        XCTAssertFalse(first.reachedEnd, "playback stopped on its own first tick")
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
    /// is nil here for the same reason it was nil when the editor opened, so a player whose clock
    /// came from `NSScreen.main.displayLink` got nothing and never ticked again.
    @MainActor
    func testAPlayerGetsAClockEvenWithNoKeyWindow() {
        XCTAssertNil(NSApplication.shared.keyWindow,
                     "precondition: this suite is meaningful only without a key window")

        let player = StudioPlayer(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-recording.mov"))

        XCTAssertTrue(player.isTicking,
                      "no display link, so tick() never runs: no playhead, no redraw, no decoded frame")
    }

    /// **Pressing Play, end to end, over a real file.**
    ///
    /// This is the user's report — "when I click on play the streaming does not actually work on
    /// the scroll bar" — as an assertion. Before the fix the playhead never moved at all: the clock
    /// came from `NSScreen.main.displayLink`, which was nil here for the same reason it was nil in
    /// the app.
    ///
    /// **Only the transport is asserted, not the picture.** `AVPlayerItemVideoOutput` delivers
    /// nothing in a headless test host, so a decode assertion here would fail for reasons that have
    /// nothing to do with the code. Real decoded pixels are covered where they can be:
    /// `StudioExportTests.testTheExportContainsTheCamera` compares two exported files byte for
    /// byte.
    @MainActor
    func testPlayingAdvancesThePlayheadAndProducesAFrame() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("player-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("screen.mov")
        try await Self.writeRecording(to: url, seconds: 2)

        let player = StudioPlayer(url: url)
        player.duration = 2
        XCTAssertEqual(player.playhead, 0)

        player.play()
        XCTAssertTrue(player.isPlaying, "play() refused, and said nothing")

        // The clock runs on the main run loop, so the test has to let it turn.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, player.playhead < 0.3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        player.pause()

        XCTAssertGreaterThan(player.playhead, 0.2, "the playhead never moved, so nothing plays")
        XCTAssertFalse(player.isPlaying)
    }

    /// A small, real, decodable movie — solid frames written the way the recorder writes them.
    private static func writeRecording(to url: URL, seconds: Double) async throws {
        let size = CGSize(width: 160, height: 120)
        let writer = try RecordingWriter(url: url, size: size, fps: 60)
        for index in 0..<Int(seconds * 60) {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(40 + index % 180),
                       CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            var format: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                         formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 60),
                presentationTimeStamp: CMTime(seconds: Double(index) / 60,
                                              preferredTimescale: 600),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescription: try XCTUnwrap(format),
                                                     sampleTiming: &timing,
                                                     sampleBufferOut: &sample)
            writer.append(try XCTUnwrap(sample))
        }
        await writer.finish()
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
