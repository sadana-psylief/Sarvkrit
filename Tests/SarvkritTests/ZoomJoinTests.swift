import CoreGraphics
import XCTest
@testable import Sarvkrit

/// What happens between two zooms that follow each other closely.
///
/// **"The zoom first goes to 2.5x then 1x and then to 1.4x, creating a weird animation."** It did,
/// by construction: `transform` found the one segment containing the moment and computed
/// `interpolate(from: 1, to: segment.level, …)` — `from:` being the literal 1. The resolver saw one
/// segment at a time, held no state, and had no idea a neighbour existed, so every ramp was
/// measured against identity at both ends. Two abutting segments therefore spent the first's
/// ease-out falling to 1× and the second's ease-in climbing back.
///
/// Nothing caught it because **every existing resolver test passes a single-element array**, and
/// the planner test that checks spacing explicitly permits `a.end == b.start`. So every test here
/// passes more than one segment.
final class ZoomJoinTests: XCTestCase {

    private let frame = CGSize(width: 1000, height: 800)

    private func segment(_ start: TimeInterval, _ end: TimeInterval, level: Double,
                         at anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> ZoomSegment {
        ZoomSegment(start: start, end: end, level: level, anchor: .fixed(anchor))
    }

    private func scale(_ segments: [ZoomSegment], at t: TimeInterval) -> Double {
        ZoomResolver.transform(at: t, segments: segments, cursor: nil, frameSize: frame).scale
    }

    private func centre(_ segments: [ZoomSegment], at t: TimeInterval) -> CGPoint {
        ZoomResolver.transform(at: t, segments: segments, cursor: nil, frameSize: frame).center
    }

    /// Every 20 ms across a window, which is finer than a frame at 60 fps.
    private func samples(_ segments: [ZoomSegment],
                         from: TimeInterval, to: TimeInterval) -> [(t: TimeInterval, scale: Double)] {
        stride(from: from, through: to, by: 0.02).map { ($0, scale(segments, at: $0)) }
    }

    // MARK: - The reported bug

    /// The exact pair out of the user's own recording: `27.63 → 33.65 at 1.38×` following
    /// `21.57 → 27.63 at 2.50×`, abutting to the frame.
    func testTwoAbuttingZoomsNeverPassThroughOneTimes() {
        let segments = [segment(21.57, 27.63, level: 2.50),
                        segment(27.63, 33.65, level: 1.38)]

        let across = samples(segments, from: 26.5, to: 29.0)
        let lowest = across.min { $0.scale < $1.scale }!
        XCTAssertGreaterThan(lowest.scale, 1.30,
                             "the frame dropped to \(lowest.scale)× at \(lowest.t)s, "
                             + "between a 2.5× zoom and a 1.38× one")
    }

    /// And it gets there in one movement rather than two: sampled across the join, the scale only
    /// ever descends.
    func testTheJoinIsOneContinuousMove() {
        let segments = [segment(21.57, 27.63, level: 2.50),
                        segment(27.63, 33.65, level: 1.38)]

        let across = samples(segments, from: 26.5, to: 29.0).map(\.scale)
        for (earlier, later) in zip(across, across.dropFirst()) {
            XCTAssertLessThanOrEqual(later, earlier + 0.001,
                                     "the scale went back up, so the frame changed direction")
        }
        XCTAssertEqual(across.first ?? 0, 2.50, accuracy: 0.01)
        XCTAssertEqual(across.last ?? 0, 1.38, accuracy: 0.01)
    }

    /// Upwards too — the other pair in the same recording is `1.69×` followed by `2.50×`.
    func testAJoinThatZoomsFurtherInIsAlsoOneMove() {
        let segments = [segment(11.02, 17.46, level: 1.69),
                        segment(17.46, 19.66, level: 2.50)]

        let across = samples(segments, from: 16.5, to: 18.5).map(\.scale)
        for (earlier, later) in zip(across, across.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later, earlier - 0.001, "the scale dipped on the way up")
        }
        XCTAssertEqual(across.first ?? 0, 1.69, accuracy: 0.01)
        XCTAssertEqual(across.last ?? 0, 2.50, accuracy: 0.01)
    }

    /// A short gap is still a join. The user's recording has a 0.40 s one, and during it the frame
    /// should hold rather than resolve to identity because no segment covers the moment.
    func testAShortGapHoldsRatherThanZoomingOut() {
        let segments = [segment(5.0, 10.0, level: 2.5),
                        segment(10.4, 15.0, level: 1.4)]

        XCTAssertEqual(scale(segments, at: 10.2), 2.5, accuracy: 0.01,
                       "the frame zoomed out during a 0.4s gap between two zooms")
        let lowest = samples(segments, from: 9.0, to: 12.0).min { $0.scale < $1.scale }!
        XCTAssertGreaterThan(lowest.scale, 1.35)
    }

    /// **A real pause is still a zoom out.** Holding a 2.5× close-up across three seconds of
    /// nothing happening would be worse than the dip — the shot has to breathe.
    func testALongGapStillReturnsToOneTimes() {
        let segments = [segment(5.0, 10.0, level: 2.5),
                        segment(13.0, 18.0, level: 1.4)]

        XCTAssertEqual(scale(segments, at: 11.5), 1.0, accuracy: 0.01)
    }

    // MARK: - The ends of a run are unchanged

    func testTheFirstZoomOfARunStillEasesInFromOneTimes() {
        let segments = [segment(5.0, 10.0, level: 2.5),
                        segment(10.0, 15.0, level: 1.4)]
        XCTAssertEqual(scale(segments, at: 5.0), 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(scale(segments, at: 5.3), 1.0)
    }

    func testTheLastZoomOfARunStillEasesOutToOneTimes() {
        let segments = [segment(5.0, 10.0, level: 2.5),
                        segment(10.0, 15.0, level: 1.4)]
        XCTAssertEqual(scale(segments, at: 15.0 - 0.001), 1.0, accuracy: 0.05)
        XCTAssertEqual(scale(segments, at: 16.0), 1.0, accuracy: 0.001)
    }

    // MARK: - The frame moves once, not twice

    /// **The centre travels with the scale.** `clamp` collapses the centre to the middle at 1×, so
    /// the old dip also panned the picture to the centre of the screen and back out again. With no
    /// dip the scale is continuous, and the anchor must be too — otherwise the join is a smooth
    /// zoom with an instant jump sideways inside it.
    func testTheCentreDoesNotJumpAtAJoin() {
        let segments = [segment(5.0, 10.0, level: 2.0, at: CGPoint(x: 0.3, y: 0.3)),
                        segment(10.0, 15.0, level: 2.0, at: CGPoint(x: 0.7, y: 0.7))]

        let before = centre(segments, at: 9.98)
        let after = centre(segments, at: 10.02)
        XCTAssertEqual(before.x, after.x, accuracy: 0.02, "the frame jumped sideways at the join")
        XCTAssertEqual(before.y, after.y, accuracy: 0.02)
    }

    /// And it arrives, rather than easing towards the old anchor forever.
    func testTheCentreReachesTheNewAnchor() {
        let segments = [segment(5.0, 10.0, level: 2.0, at: CGPoint(x: 0.3, y: 0.3)),
                        segment(10.0, 15.0, level: 2.0, at: CGPoint(x: 0.7, y: 0.7))]

        let settled = centre(segments, at: 12.0)
        XCTAssertEqual(settled.x, 0.7, accuracy: 0.01)
        XCTAssertEqual(settled.y, 0.7, accuracy: 0.01)
    }

    /// A held shot is not a moving one, so the renderer has nothing to blur across a gap where the
    /// frame is standing still.
    func testAHeldGapIsNotMoving() {
        let segments = [segment(5.0, 10.0, level: 2.5),
                        segment(10.4, 15.0, level: 1.4)]
        XCTAssertFalse(ZoomResolver.transform(at: 10.2, segments: segments, cursor: nil,
                                              frameSize: frame).isMoving)
    }

    // MARK: - A cut still wins

    /// **A clip boundary must still make a zoom ease out.** Suppressing the ease-out at a join must
    /// not suppress it at a cut, where the picture is about to jump to different material — that is
    /// the pop the previous round fixed, and it would come straight back.
    func testAZoomStillEasesOutAtACutEvenWithANeighbourAfterIt() {
        let segments = [segment(5.0, 10.0, level: 2.5),
                        segment(10.0, 15.0, level: 1.4)]

        // The clip ends at 8.0, partway through the first segment.
        let atTheCut = ZoomResolver.transform(at: 7.99, segments: segments, cursor: nil,
                                              frameSize: frame, clipSource: 5.0..<8.0)
        XCTAssertEqual(atTheCut.scale, 1.0, accuracy: 0.1,
                       "the zoom did not ease out at the cut")
    }

    // MARK: - Order and disabling

    /// Segments arriving out of order must not change which one is the neighbour.
    func testTheNeighbourIsFoundRegardlessOfArrayOrder() {
        let ordered = [segment(5.0, 10.0, level: 2.5), segment(10.0, 15.0, level: 1.4)]
        let shuffled = [ordered[1], ordered[0]]
        XCTAssertEqual(scale(shuffled, at: 10.2), scale(ordered, at: 10.2), accuracy: 0.001)
    }

    /// A disabled neighbour is not a neighbour — the frame has nothing to hold at, so it zooms out.
    func testADisabledNeighbourDoesNotJoin() {
        var disabled = segment(5.0, 10.0, level: 2.5)
        disabled.isDisabled = true
        let segments = [disabled, segment(10.4, 15.0, level: 1.4)]
        XCTAssertEqual(scale(segments, at: 10.2), 1.0, accuracy: 0.01)
    }
}
