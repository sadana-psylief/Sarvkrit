import AppKit
import XCTest
@testable import Sarvkrit

/// Dragging an arrow's middle to bend it.
///
/// The maths was already all here — `curvature` was stored, encoded, rendered as a quadratic and
/// hit-tested along the curve — and **nothing in the app ever wrote it**. There was a `.curve`
/// handle case that was never positioned, never drawn and never returned by hit-testing.
final class ArrowBowTests: XCTestCase {

    private let start = CGPoint(x: 100, y: 100)
    private let end = CGPoint(x: 300, y: 100)

    func testTheBowSitsOnTheChordWhenThereIsNoCurve() {
        let bow = SelectionHandles.bowPoint(start: start, end: end, curvature: 0)
        XCTAssertEqual(bow.x, 200, accuracy: 0.001)
        XCTAssertEqual(bow.y, 100, accuracy: 0.001)
    }

    func testTheBowSitsWhereTheCurveActuallyIs() {
        // Half the control offset, because a quadratic reaches half of it at the midpoint. Getting
        // this wrong puts the handle somewhere the arrow visibly is not.
        let curvature: CGFloat = 80
        let bow = SelectionHandles.bowPoint(start: start, end: end, curvature: curvature)
        let spine = ArrowGeometry.spinePoints(from: start, to: end, curvature: curvature)
        let middle = spine[spine.count / 2]
        XCTAssertEqual(bow.x, middle.x, accuracy: 1)
        XCTAssertEqual(bow.y, middle.y, accuracy: 1)
    }

    func testTheInverseRoundTrips() {
        for curvature in [CGFloat(-120), -40, 0, 25, 90] {
            let bow = SelectionHandles.bowPoint(start: start, end: end, curvature: curvature)
            let back = SelectionHandles.curvature(forBowAt: bow, start: start, end: end)
            XCTAssertEqual(back, curvature, accuracy: 0.001)
        }
    }

    func testDraggingTheBowOntoTheChordStraightensIt() {
        // The thing that was impossible before: the bow was substituted on every read, so any
        // value under the threshold became the default again and a curve could not be undone.
        let onChord = CGPoint(x: 200, y: 100)
        let curvature = SelectionHandles.curvature(forBowAt: onChord, start: start, end: end)
        XCTAssertEqual(curvature, 0, accuracy: 0.001)
        XCTAssertTrue(ArrowGeometry.isStraight(curvature))
    }

    func testDraggingAlongTheArrowDoesNotBendIt() {
        // Only the sideways component counts, so sliding the handle towards either end leaves the
        // shape alone instead of bending it by an amount nobody asked for.
        let alongTheChord = CGPoint(x: 260, y: 100)
        XCTAssertEqual(SelectionHandles.curvature(forBowAt: alongTheChord,
                                                  start: start, end: end),
                       0, accuracy: 0.001)
    }

    func testBendingWorksOnADiagonalArrow() {
        // The normal is derived from the chord, so this must hold at any angle — not just the
        // horizontal one that is easy to reason about.
        let a = CGPoint(x: 50, y: 40)
        let b = CGPoint(x: 250, y: 190)
        for curvature in [CGFloat(-70), 35, 110] {
            let bow = SelectionHandles.bowPoint(start: a, end: b, curvature: curvature)
            XCTAssertEqual(SelectionHandles.curvature(forBowAt: bow, start: a, end: b),
                           curvature, accuracy: 0.001)
        }
    }

    func testTheThreeHandlesAreTheEndsAndTheBow() {
        let handles = SelectionHandles.arrowHandles(start: start, end: end, curvature: 0)
        XCTAssertEqual(Set(handles.keys), [.start, .end, .curve])
        XCTAssertTrue(handles[.start]!.contains(start))
        XCTAssertTrue(handles[.end]!.contains(end))
    }

    func testAZeroLengthArrowDoesNotProduceNaN() {
        let bow = SelectionHandles.bowPoint(start: start, end: start, curvature: 50)
        XCTAssertFalse(bow.x.isNaN)
        XCTAssertFalse(bow.y.isNaN)
        let back = SelectionHandles.curvature(forBowAt: bow, start: start, end: start)
        XCTAssertFalse(back.isNaN)
    }

    /// Selection and drawing must agree about where a bowed arrow is.
    func testABowedArrowIsHitTestedAlongItsCurveNotItsChord() {
        // `flatten` compared the raw curvature against zero while the renderer used a threshold,
        // so a bowed arrow could be drawn curved and selected as a straight chord.
        var arrow = ArrowElement(start: start, end: end)
        arrow.curvature = 90
        arrow.head = .curved
        var document = AnnotationDocument(imageSize: CGSize(width: 400, height: 400))
        let element = AnnotationElement(kind: .arrow(arrow))
        document.elements = [element]

        let onTheCurve = SelectionHandles.bowPoint(start: start, end: end, curvature: 90)
        XCTAssertEqual(AnnotationGeometry.hitTest(document, at: onTheCurve, tolerance: 8),
                       element.id, "the curve is not where selection thinks it is")
        XCTAssertNil(AnnotationGeometry.hitTest(document, at: CGPoint(x: 200, y: 100),
                                                tolerance: 4),
                     "the chord is empty space for a bowed arrow")
    }
}
