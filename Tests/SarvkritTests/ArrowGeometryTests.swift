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

    /// The measured reference proportions, which are the whole point of this file.
    ///
    /// **Re-measured off `markup.mp4` (frame t=15.0s, native resolution).** The previous numbers
    /// came from a different reference arrow and got two things wrong: they tapered the shaft
    /// from 0.35W at the tail to W at the neck, and they drew a head 2.85W across. Measured, the
    /// shaft is a constant W end to end and the head is 4.5W across.
    func testTheProportionsMatchTheMeasuredReference() {
        let w: CGFloat = 12
        let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: w, length: 400)
        XCTAssertEqual(metrics.neckHalf, w * 0.5, accuracy: 0.001, "shaft is W at the junction")
        XCTAssertEqual(metrics.tailHalf, w * 0.5, accuracy: 0.001, "and W at the tail — no taper")
        XCTAssertEqual(metrics.headLength, w * 2.8, accuracy: 0.001)
        XCTAssertEqual(metrics.headHalf, w * 2.25, accuracy: 0.001, "4.5W barb to barb")
        XCTAssertEqual(metrics.barbSetback, w * 0.3, accuracy: 0.001,
                       "the barbs sit behind the junction — that is what makes it look swept")
    }

    func testTheOpenStyleIsStrokedNotFilled() {
        // Four styles that all fill would make the open chevron impossible.
        guard case .stroke = ArrowGeometry.shape(from: .zero, to: CGPoint(x: 100, y: 0),
                                                 curvature: 0, head: .open, strokeWidth: 8)
        else { return XCTFail("open should stroke") }
        guard case .fill = ArrowGeometry.shape(from: .zero, to: CGPoint(x: 100, y: 0),
                                               curvature: 0, head: .filled, strokeWidth: 8)
        else { return XCTFail("filled should fill") }
    }

    func testAShortArrowKeepsAVisibleHead() {
        // It used to lose the head entirely once the shaft minimum could not be met.
        let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: 16, length: 30)
        XCTAssertGreaterThan(metrics.headLength, 4, "the head must not vanish")
        XCTAssertLessThan(metrics.headLength, 30 * 0.55, "and must not eat the shaft")
    }

    func testTheOutlineIsClosedAndNonEmpty() {
        let box = path().boundingBox
        XCTAssertFalse(box.isNull)
        XCTAssertGreaterThan(box.width, 100)
    }

    func testTheDefaultShaftIsConstantWidth() {
        // Measured off the reference: the shaft is one width from the tail cap to the neck. It
        // used to taper 0.35W -> W, which drew the tail at a third of its true width and made
        // the whole mark read spindlier than the reference.
        for head in [ArrowElement.Head.filled, .curved] {
            let metrics = ArrowGeometry.metrics(for: head, strokeWidth: 10, length: 200)
            XCTAssertEqual(metrics.tailHalf, metrics.neckHalf, accuracy: 0.001,
                           "\(head) should not taper")
        }
    }

    func testTheThinStyleStillTapers() {
        // The one style that keeps a taper, so the four remain visibly different marks rather
        // than four widths of the same one.
        let metrics = ArrowGeometry.metrics(for: .thin, strokeWidth: 10, length: 200)
        XCTAssertLessThan(metrics.tailHalf, metrics.neckHalf)
    }

    func testTheHeadIsWiderThanTheShaft() {
        let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: 10, length: 200)
        XCTAssertGreaterThan(metrics.headHalf, metrics.neckHalf)
    }

    func testTheBackEdgeIsSweptNotFlat() {
        // Zero setback is a plain triangle sitting on a stick.
        for head in [ArrowElement.Head.filled, .thin, .curved] {
            let metrics = ArrowGeometry.metrics(for: head, strokeWidth: 10, length: 200)
            XCTAssertGreaterThan(metrics.barbSetback, 0, "\(head) lost its sweep")
            XCTAssertLessThan(metrics.barbSetback, metrics.headLength * 0.25,
                              "\(head) is over-swept and grows spurs")
        }
    }

    func testTheShaftAlwaysSurvives() {
        // The reference allows a head of 3W against a shaft of 2W, so at exactly five widths of
        // length the head is legitimately 60% of the arrow. What must never happen is the head
        // reaching the tail.
        for width in [CGFloat(4), 12, 26, 40] {
            for length in [CGFloat(24), 60, 140, 400] {
                let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: width,
                                                    length: length)
                XCTAssertGreaterThan(length - metrics.headLength, 0,
                                     "w=\(width) len=\(length): no shaft left")
                XCTAssertLessThanOrEqual(metrics.headLength, max(length - width * 2,
                                                                 length * 0.45) + 0.001,
                                         "w=\(width) len=\(length): past the cap")
            }
        }
    }

    func testTheHeadNeverBecomesWiderThanItIsLong() {
        // Half-span against length, not full span: measured, the head is 4.5W across and 2.8W
        // long, so it *is* wider than it is long. What must hold is that each barb stays inside
        // the head's reach — past that the barbs splay forward and the point stops reading.
        // The margin is now 0.80, where the old narrow head sat at 0.475.
        for width in [CGFloat(2), 6, 14, 26, 40] {
            for length in [CGFloat(30), 90, 400] {
                let metrics = ArrowGeometry.metrics(for: .filled, strokeWidth: width,
                                                    length: length)
                XCTAssertLessThanOrEqual(metrics.headHalf, metrics.headLength,
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
        // Measured on the top edge rather than the box height. A bowed arrow's head tilts with
        // the curve, so its *vertical* extent shrinks even as the shaft rises — comparing heights
        // makes a clearly bowed arrow look barely different from a straight one.
        let straight = path(.filled, curvature: 0).boundingBox
        let bowed = path(.filled, curvature: 60).boundingBox
        XCTAssertGreaterThan(bowed.maxY, straight.maxY + 10,
                             "the shaft should rise well above a straight arrow's edge")
    }

    func testTheFourStylesAreActuallyDifferent() {
        // Four buttons that render the same thing would be four buttons that do nothing. `curved`
        // shares its proportions with `filled` on purpose — what separates them is the default
        // bow, so it has to be compared as a drawn shape rather than as numbers.
        // `.curved` shares its proportions with `.filled`; what separates them is the bow, which
        // is now written into the element when it is created rather than substituted on every
        // read. That change is what lets the bow handle drag a curve back to straight.
        let bow = ArrowGeometry.defaultCurvature(from: .zero, to: CGPoint(x: 200, y: 0))
        let straight = path(.filled).boundingBox
        let curved = path(.curved, curvature: bow).boundingBox
        XCTAssertGreaterThan(curved.maxY, straight.maxY + 3, "a curved arrow must bow")

        let thin = ArrowGeometry.metrics(for: .thin, strokeWidth: 10, length: 200)
        let filled = ArrowGeometry.metrics(for: .filled, strokeWidth: 10, length: 200)
        XCTAssertNotEqual(thin.headHalf, filled.headHalf)

        guard case .stroke = ArrowGeometry.shape(from: .zero, to: CGPoint(x: 200, y: 0),
                                                 curvature: 0, head: .open, strokeWidth: 10)
        else { return XCTFail("open should be the stroked one") }
    }

    func testStoredZeroAlwaysMeansStraight() {
        // **The regression test for being able to straighten a curve.** The bow used to be a
        // fallback applied on every read: any stored value under the threshold became the default
        // bow, so a `.curved` arrow could not be dragged flat no matter where the handle went.
        // Measured on the spine, not the drawn path: an arrowhead is wide whether or not the
        // shaft bends, so a bounding box says nothing about straightness.
        let end = CGPoint(x: 200, y: 0)
        for head in ArrowElement.Head.allCases {
            let spine = ArrowGeometry.spinePoints(from: .zero, to: end, curvature: 0)
            let drift = spine.map { abs($0.y) }.max() ?? 0
            XCTAssertLessThan(drift, 0.01, "\(head) with no curvature still bows by \(drift)")
        }

        // And with the default bow it does leave the chord, so the two cases are distinguishable.
        let bowed = ArrowGeometry.spinePoints(
            from: .zero, to: end,
            curvature: ArrowGeometry.defaultCurvature(from: .zero, to: end))
        XCTAssertGreaterThan(bowed.map { abs($0.y) }.max() ?? 0, 10)
    }

    func testTheDefaultBowIsSevenPercentOfTheChord() {
        // A quadratic reaches half its control offset at the midpoint, hence the doubling.
        XCTAssertEqual(ArrowGeometry.defaultCurvature(from: .zero, to: CGPoint(x: 100, y: 0)),
                       14, accuracy: 0.001)
        XCTAssertEqual(ArrowGeometry.defaultCurvature(from: .zero, to: CGPoint(x: 200, y: 0)),
                       28, accuracy: 0.001)
    }

    func testTheStraightThresholdIsSharedRatherThanRepeated() {
        XCTAssertTrue(ArrowGeometry.isStraight(0))
        XCTAssertTrue(ArrowGeometry.isStraight(0.005))
        XCTAssertFalse(ArrowGeometry.isStraight(1))
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
