import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Turning a list of zoom segments into the one transform a frame is drawn with.
///
/// **The clamp is the part that must not be got wrong.** A zoomed frame whose centre drifts past
/// the edge of the recording shows background through the middle of the picture — which looks like
/// a rendering fault, not a framing choice — so the centre is always pulled back inside.
final class ZoomResolverTests: XCTestCase {

    private let frame = CGSize(width: 1000, height: 1000)

    private func resolve(_ segments: [ZoomSegment], at t: TimeInterval,
                         cursor: CGPoint? = nil) -> ZoomTransform {
        ZoomResolver.transform(at: t, segments: segments, cursor: cursor, frameSize: frame)
    }

    private func segment(_ start: TimeInterval, _ end: TimeInterval, level: Double = 2,
                         anchor: ZoomSegment.Anchor = .fixed(CGPoint(x: 0.5, y: 0.5)))
        -> ZoomSegment {
        ZoomSegment(start: start, end: end, level: level, anchor: anchor)
    }

    // MARK: - Nothing to do

    func testWithNoZoomsTheFrameIsUntouched() {
        let transform = resolve([], at: 5)
        XCTAssertEqual(transform.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.center.x, 0.5, accuracy: 0.0001)
    }

    func testBeforeAnySegmentTheFrameIsUntouched() {
        XCTAssertEqual(resolve([segment(10, 20)], at: 0).scale, 1, accuracy: 0.0001)
    }

    func testAfterEverySegmentTheFrameIsBack() {
        XCTAssertEqual(resolve([segment(1, 2)], at: 30).scale, 1, accuracy: 0.0001)
    }

    // MARK: - Easing

    func testAtTheStartOfASegmentTheZoomHasNotBegun() {
        XCTAssertEqual(resolve([segment(5, 10)], at: 5).scale, 1, accuracy: 0.001)
    }

    func testTheZoomIsFullyInAfterItsEase() {
        let one = segment(5, 10)
        XCTAssertEqual(resolve([one], at: 5 + one.easeIn + 0.01).scale, 2, accuracy: 0.01)
    }

    func testTheZoomIsPartlyInDuringItsEase() {
        let one = segment(5, 10)
        let scale = resolve([one], at: 5 + one.easeIn / 2).scale
        XCTAssertGreaterThan(scale, 1)
        XCTAssertLessThan(scale, 2)
    }

    func testTheZoomIsBackOutByTheEnd() {
        XCTAssertEqual(resolve([segment(5, 10)], at: 10).scale, 1, accuracy: 0.01)
    }

    /// A zoom that begins on frame zero opens already zoomed. Nobody wants their video to start by
    /// moving; if the first thing to show is a close-up, it should simply be there.
    func testAZoomStartingAtZeroOpensAlreadyZoomed() {
        XCTAssertEqual(resolve([segment(0, 10)], at: 0).scale, 2, accuracy: 0.01)
    }

    func testADisabledSegmentDoesNothing() {
        var one = segment(5, 10)
        one.isDisabled = true
        XCTAssertEqual(resolve([one], at: 7).scale, 1, accuracy: 0.0001)
    }

    func testAnInstantSegmentIsAtFullLevelImmediately() {
        var one = segment(5, 10)
        one.ease = .instant
        XCTAssertEqual(resolve([one], at: 5.001).scale, 2, accuracy: 0.01)
    }

    // MARK: - Clamping

    /// At 1x the whole frame is visible, so there is only one legal centre.
    func testAtNoZoomTheCentreIsTheCentre() {
        let one = segment(5, 10, level: 1, anchor: .fixed(CGPoint(x: 0, y: 0)))
        let transform = resolve([one], at: 7)
        XCTAssertEqual(transform.center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(transform.center.y, 0.5, accuracy: 0.0001)
    }

    /// An anchor in the corner would show background through the frame. It is pulled in to the
    /// nearest legal position instead.
    func testAnAnchorInTheCornerIsPulledInside() {
        let one = segment(0, 10, level: 2, anchor: .fixed(CGPoint(x: 0, y: 0)))
        let transform = resolve([one], at: 5)
        XCTAssertEqual(transform.center.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(transform.center.y, 0.25, accuracy: 0.001)
    }

    func testAnAnchorAtTheFarCornerIsPulledInsideToo() {
        let one = segment(0, 10, level: 2, anchor: .fixed(CGPoint(x: 1, y: 1)))
        let transform = resolve([one], at: 5)
        XCTAssertEqual(transform.center.x, 0.75, accuracy: 0.001)
    }

    func testACentredAnchorIsLeftAlone() {
        let one = segment(0, 10, level: 4, anchor: .fixed(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(resolve([one], at: 5).center.x, 0.5, accuracy: 0.001)
    }

    /// The invariant, over every level and every anchor: the visible rectangle stays inside the
    /// recording. This is the one that catches a clamp written for the wrong axis.
    func testTheVisibleRectangleNeverLeavesTheRecording() {
        for level in stride(from: 1.0, through: 4.0, by: 0.25) {
            for x in stride(from: -0.5, through: 1.5, by: 0.1) {
                let one = segment(0, 10, level: level,
                                  anchor: .fixed(CGPoint(x: x, y: x)))
                let transform = resolve([one], at: 5)
                let half = 0.5 / transform.scale
                XCTAssertGreaterThanOrEqual(transform.center.x - half, -0.0001, "\(level) \(x)")
                XCTAssertLessThanOrEqual(transform.center.x + half, 1.0001, "\(level) \(x)")
            }
        }
    }

    // MARK: - Following

    func testAFollowingSegmentUsesTheCursor() {
        let one = segment(0, 10, level: 2, anchor: .followCursor)
        let transform = resolve([one], at: 5, cursor: CGPoint(x: 700, y: 700))
        XCTAssertGreaterThan(transform.center.x, 0.5)
    }

    /// With no cursor there is nothing to follow, and the middle is the only honest answer.
    func testAFollowingSegmentWithNoCursorCentresItself() {
        let one = segment(0, 10, level: 2, anchor: .followCursor)
        XCTAssertEqual(resolve([one], at: 5, cursor: nil).center.x, 0.5, accuracy: 0.001)
    }

    /// Inside the dead zone the frame is still. Tracking a pointer that has barely moved reads as
    /// drift, and drift over a whole demo is what makes people feel seasick.
    func testASmallCursorMovementDoesNotMoveTheFrame() {
        let one = segment(0, 10, level: 2, anchor: .followCursor)
        let centre = resolve([one], at: 5, cursor: CGPoint(x: 500, y: 500)).center
        let nudged = resolve([one], at: 5, cursor: CGPoint(x: 540, y: 500)).center
        XCTAssertEqual(centre.x, nudged.x, accuracy: 0.001)
    }

    // MARK: - Motion

    /// The renderer blurs the frame only while the transform is actually travelling, so a static
    /// zoomed shot costs nothing.
    func testTheTransformSaysWhenItIsMoving() {
        let one = segment(5, 10)
        XCTAssertTrue(resolve([one], at: 5 + one.easeIn / 2).isMoving)
        XCTAssertFalse(resolve([one], at: 7.5).isMoving)
    }

    // MARK: - Cuts

    /// **A zoom that straddles a cut must ease out at the cut, not snap.**
    ///
    /// Source time is not monotonic in output time once the edit has a cut in it: the frame after a
    /// boundary can come from anywhere in the recording. A ramp measured from the segment's own end
    /// is therefore still mid-flight when the picture jumps, and the zoom pops.
    ///
    /// This is a defect today rather than one reordering introduces — any ripple-delete already
    /// creates that discontinuity — but reordering makes it happen at every cut instead of
    /// occasionally, so it is fixed here.
    func testAZoomEasesOutAtACutRatherThanSnapping() {
        // A zoom running 8…12, on a clip whose material stops at 10.
        let zoomed = ZoomResolver.transform(at: 9, segments: [segment(8, 12)], cursor: nil,
                                            frameSize: frame, clipSource: 0..<10)
        let atTheCut = ZoomResolver.transform(at: 9.99, segments: [segment(8, 12)], cursor: nil,
                                              frameSize: frame, clipSource: 0..<10)

        XCTAssertGreaterThan(zoomed.scale, 1.5, "the zoom should be in by the middle of the clip")
        XCTAssertEqual(atTheCut.scale, 1, accuracy: 0.05,
                       "the zoom was still mid-ramp at the cut, so it snaps")
    }

    /// And a clip that begins inside a zoom opens already zoomed, rather than ramping in from
    /// nothing just after a cut — which would read as a mistake. Same reasoning as a zoom that
    /// begins on frame zero.
    func testAClipThatBeginsInsideAZoomOpensAlreadyZoomed() {
        let transform = ZoomResolver.transform(at: 9.05, segments: [segment(8, 12)], cursor: nil,
                                               frameSize: frame, clipSource: 9..<12)
        XCTAssertEqual(transform.scale, 2, accuracy: 0.0001)
    }

    /// With no clip range the arithmetic is exactly what it always was, so nothing that does not
    /// cut is affected.
    func testWithoutAClipRangeNothingChanges() {
        let withRange = ZoomResolver.transform(at: 9, segments: [segment(8, 12)], cursor: nil,
                                               frameSize: frame, clipSource: nil)
        XCTAssertEqual(withRange.scale, resolve([segment(8, 12)], at: 9).scale, accuracy: 0.0001)
    }
}
