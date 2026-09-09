import XCTest
@testable import Sarvkrit

/// Emphasising where the pointer is, for a stretch.
///
/// **There was no way to point at anything.** `CursorSettings` is entirely global — not one field is
/// time-ranged — so "look here, now" could not be expressed at all. The nearest thing was
/// `StudioMask.Mode.highlight`, a hand-drawn rectangle with a start and end, which does not move and
/// is not attached to the pointer.
///
/// This follows the pointer, which is the thing worth pointing at: the cursor's own recorded position
/// is the centre, so it tracks whatever was being demonstrated without anybody drawing a box.
final class PointerSpotlightTests: XCTestCase {

    private let frame = CGSize(width: 1000, height: 600)
    private func highlight(_ start: TimeInterval, _ end: TimeInterval) -> PointerHighlight {
        PointerHighlight(start: start, end: end)
    }

    func testNothingOutsideItsRange() {
        XCTAssertNil(PointerSpotlight.state(at: 9, highlights: [highlight(1, 3)],
                                            cursor: CGPoint(x: 100, y: 100), frameSize: frame))
    }

    func testCentredOnTheCursor() throws {
        let state = try XCTUnwrap(PointerSpotlight.state(
            at: 2, highlights: [highlight(1, 3)],
            cursor: CGPoint(x: 420, y: 380), frameSize: frame))

        XCTAssertEqual(state.centre, CGPoint(x: 420, y: 380))
    }

    /// **From the shorter side.** Taking it from the width would make the same setting a very
    /// different spotlight on a wide recording than on a tall one.
    func testTheRadiusComesFromTheShorterSide() throws {
        var spot = highlight(1, 3)
        spot.radiusFraction = 0.1
        let state = try XCTUnwrap(PointerSpotlight.state(
            at: 2, highlights: [spot], cursor: .zero, frameSize: frame))

        XCTAssertEqual(state.radius, 60, accuracy: 0.001)
    }

    /// With no cursor sample there is nothing to point at, and inventing a centre would put the
    /// spotlight in the corner.
    func testNothingWhenTheCursorIsUnknown() {
        XCTAssertNil(PointerSpotlight.state(at: 2, highlights: [highlight(1, 3)],
                                            cursor: nil, frameSize: frame))
    }

    /// It fades in and out rather than snapping, the way the camera's layout changes do — a
    /// spotlight appearing between two frames reads as a flash.
    func testItFadesInAndOutRatherThanSnapping() throws {
        var spot = highlight(0, 4)
        spot.transition = 0.5
        spot.dimming = 0.6

        let entering = try XCTUnwrap(PointerSpotlight.state(
            at: 0.1, highlights: [spot], cursor: .zero, frameSize: frame))
        let middle = try XCTUnwrap(PointerSpotlight.state(
            at: 2, highlights: [spot], cursor: .zero, frameSize: frame))
        let leaving = try XCTUnwrap(PointerSpotlight.state(
            at: 3.9, highlights: [spot], cursor: .zero, frameSize: frame))

        XCTAssertLessThan(entering.dimming, middle.dimming)
        XCTAssertLessThan(leaving.dimming, middle.dimming)
        XCTAssertEqual(middle.dimming, 0.6, accuracy: 0.001)
    }

    /// Overlapping spotlights are the user's business; the first that covers the moment wins, so
    /// the result is never two dimmings multiplied into darkness.
    func testOnlyOneSpotlightAtATime() throws {
        let state = try XCTUnwrap(PointerSpotlight.state(
            at: 2, highlights: [highlight(1, 3), highlight(1.5, 4)],
            cursor: .zero, frameSize: frame))
        XCTAssertNotNil(state)
    }
}
