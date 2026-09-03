import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The arrow's shape.
///
/// It is built as one filled outline rather than a stroked line with a triangle on the end,
/// because the stuck-on version always reads as clip art. These pin the properties that make the
/// difference, all of which were wrong at some point while tuning it.
final class ArrowGeometryTests: XCTestCase {

    private func path(_ head: ArrowElement.Head = .filled,
                      from: CGPoint = .zero, to: CGPoint = CGPoint(x: 200, y: 0),
                      curvature: CGFloat = 0, width: CGFloat = 10) -> CGPath {
        ArrowGeometry.path(from: from, to: to, curvature: curvature,
                           head: head, strokeWidth: width)
    }

    func testTheOutlineIsClosedAndNonEmpty() {
        let box = path().boundingBox
        XCTAssertFalse(box.isNull)
        XCTAssertGreaterThan(box.width, 100)
    }

    func testTheShaftTapersFromTailToNeck() {
        // The property that gives the mark direction before you even notice the head — and the
        // thing a stroked line physically cannot do.
        let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: 10, length: 200)
        XCTAssertLessThan(metrics.tailWidth, metrics.neckWidth)
    }

    func testTheHeadIsWiderThanTheShaft() {
        let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: 10, length: 200)
        XCTAssertGreaterThan(metrics.headWidth, metrics.neckWidth)
    }

    func testTheBackEdgeIsSweptNotFlat() {
        // Zero sweep is a plain triangle. Every style keeps some.
        for head in [ArrowElement.Head.filled, .open, .thin, .curved] {
            let metrics = ArrowGeometry.metrics(for: head, strokeWidth: 10, length: 200)
            XCTAssertGreaterThan(metrics.headSweep, 0, "\(head) lost its sweep")
            XCTAssertLessThan(metrics.headSweep, 0.35, "\(head) is over-swept and grows spurs")
        }
    }

    func testAShortArrowAlwaysKeepsAVisibleShaft() {
        // At 26pt on a 60pt arrow the untamed proportions produced a signpost, not a mark. The
        // shaft has to survive even in that degenerate case — the assertion is about what the user
        // sees, not about the particular clamp that achieves it.
        for width in [CGFloat(4), 12, 26, 40] {
            for length in [CGFloat(24), 60, 140] {
                let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: width,
                                                    length: length)
                XCTAssertLessThan(metrics.headLength, length * 0.55,
                                  "w=\(width) len=\(length): the head ate the shaft")
            }
        }
    }

    func testTheHeadNeverBecomesWiderThanItIsLong() {
        // A head wider than it is long stops reading as a point and starts reading as a fin.
        for width in [CGFloat(2), 6, 14, 26, 40] {
            for length in [CGFloat(30), 90, 400] {
                let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: width,
                                                    length: length)
                XCTAssertLessThanOrEqual(metrics.headWidth, metrics.headLength,
                                         "w=\(width) len=\(length)")
            }
        }
    }

    func testTheOutlineStaysWithinAReasonableBoxAroundTheArrow() {
        // Catches a head that has flown off at the wrong angle, which is what a bad direction
        // estimate on a curved spine produces.
        let box = path(.filled, from: CGPoint(x: 50, y: 50),
                       to: CGPoint(x: 250, y: 50), width: 12).boundingBox
        XCTAssertGreaterThanOrEqual(box.minX, 40)
        XCTAssertLessThanOrEqual(box.maxX, 260)
        XCTAssertLessThan(box.height, 60, "a straight arrow should not be tall")
    }

    func testACurvedArrowBowsAwayFromTheChord() {
        // A quadratic reaches half its control offset at the midpoint, so a curvature of 60
        // displaces the spine by about 30 — the bounding box grows by that, not by 60.
        let straight = path(.curved, curvature: 0).boundingBox
        let bowed = path(.curved, curvature: 60).boundingBox
        XCTAssertGreaterThan(bowed.height, straight.height + 10)
        XCTAssertGreaterThan(bowed.height, straight.height * 1.35)
    }

    func testTheFourStylesAreActuallyDifferent() {
        // Four styles that render identically would be four buttons that do nothing.
        let boxes = [ArrowElement.Head.filled, .open, .thin, .curved].map {
            ArrowGeometry.metrics(for: $0, strokeWidth: 10, length: 200)
        }
        let signatures = Set(boxes.map { "\($0.tailWidth)-\($0.headLength)-\($0.headWidth)" })
        XCTAssertEqual(signatures.count, 4)
    }

    func testAZeroLengthArrowDoesNotCrash() {
        XCTAssertTrue(path(from: .zero, to: .zero).isEmpty)
    }

    func testTheSpineFollowsTheCurveNotTheChord() {
        let spine = ArrowGeometry.spinePoints(from: .zero, to: CGPoint(x: 200, y: 0),
                                              curvature: 50)
        let midpoint = spine[spine.count / 2]
        XCTAssertGreaterThan(abs(midpoint.y), 20, "the middle of the spine should be off the chord")
        XCTAssertGreaterThan(ArrowGeometry.polylineLength(spine), 200)
    }
}
