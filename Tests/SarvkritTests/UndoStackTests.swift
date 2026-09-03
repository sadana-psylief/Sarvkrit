import XCTest
@testable import Sarvkrit

final class UndoStackTests: XCTestCase {

    func testUndoAndRedoWalkTheHistory() {
        var stack = UndoStack(initial: 0)
        stack.commit(1)
        stack.commit(2)
        XCTAssertEqual(stack.undo(), 1)
        XCTAssertEqual(stack.undo(), 0)
        XCTAssertNil(stack.undo())
        XCTAssertEqual(stack.redo(), 1)
        XCTAssertEqual(stack.redo(), 2)
        XCTAssertNil(stack.redo())
    }

    func testANoOpCommitDoesNotGrowTheStack() {
        // Otherwise a click that changed nothing costs an undo the user has to press twice past.
        var stack = UndoStack(initial: 0)
        stack.commit(0)
        stack.commit(0)
        XCTAssertFalse(stack.canUndo)
    }

    func testANewEditClearsTheRedoBranch() {
        var stack = UndoStack(initial: 0)
        stack.commit(1)
        _ = stack.undo()
        stack.commit(9)
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.current, 9)
    }

    func testAStrokeIsOneUndoStep() {
        // The reason this isn't NSUndoManager: a continuous gesture must collapse, and doing that
        // by hand is most of what NSUndoManager would have been used for.
        var stack = UndoStack(initial: [Int]())
        stack.beginTransaction()
        var points: [Int] = []
        for value in 1...50 {
            points.append(value)
            stack.commit(points)
        }
        stack.endTransaction(points)

        XCTAssertEqual(stack.current.count, 50)
        XCTAssertEqual(stack.undo(), [], "one undo must remove the whole stroke")
        XCTAssertFalse(stack.canUndo)
    }

    func testNestedTransactionsCollapseToOne() {
        var stack = UndoStack(initial: 0)
        stack.beginTransaction()
        stack.beginTransaction()
        stack.commit(1)
        stack.endTransaction(2)
        stack.endTransaction(3)
        XCTAssertEqual(stack.current, 3)
        XCTAssertEqual(stack.undo(), 0)
    }

    func testEndingATransactionThatChangedNothingCostsNothing() {
        var stack = UndoStack(initial: 5)
        stack.beginTransaction()
        stack.endTransaction(5)
        XCTAssertFalse(stack.canUndo)
    }

    func testTheDepthLimitDropsTheOldestNotTheNewest() {
        var stack = UndoStack(initial: 0, depth: 3)
        for value in 1...10 { stack.commit(value) }
        XCTAssertEqual(stack.current, 10)
        var undone: [Int] = []
        while let value = stack.undo() { undone.append(value) }
        XCTAssertEqual(undone, [9, 8, 7], "the three most recent states are the ones kept")
    }

    func testItWorksOverADocument() {
        var document = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        var stack = UndoStack(initial: document)
        document.add(.line(LineElement(start: .zero, end: CGPoint(x: 1, y: 1))))
        stack.commit(document)
        XCTAssertEqual(stack.current.elements.count, 1)
        XCTAssertEqual(stack.undo()?.elements.count, 0)
    }
}

final class PencilSmoothingTests: XCTestCase {

    func testCollinearPointsCollapseToTwo() {
        let line = (0...20).map { CGPoint(x: Double($0) * 5, y: 100) }
        XCTAssertEqual(PencilSmoothing.simplify(line, epsilon: 1).count, 2)
    }

    func testARightAngleKeepsItsCorner() {
        let corner = (0...10).map { CGPoint(x: Double($0) * 10, y: 0) }
            + (1...10).map { CGPoint(x: 100, y: Double($0) * 10) }
        let simplified = PencilSmoothing.simplify(corner, epsilon: 1)
        XCTAssertEqual(simplified.count, 3)
        XCTAssertEqual(simplified[1], CGPoint(x: 100, y: 0))
    }

    func testEndpointsAreAlwaysPreserved() {
        let points = (0...50).map { CGPoint(x: Double($0), y: sin(Double($0) / 3) * 20) }
        let simplified = PencilSmoothing.simplify(points, epsilon: 5)
        XCTAssertEqual(simplified.first, points.first)
        XCTAssertEqual(simplified.last, points.last)
    }

    func testSimplifyingIsIdempotent() {
        let points = (0...50).map { CGPoint(x: Double($0), y: sin(Double($0) / 3) * 20) }
        let once = PencilSmoothing.simplify(points, epsilon: 3)
        XCTAssertEqual(PencilSmoothing.simplify(once, epsilon: 3), once)
    }

    func testAnEpsilonOfZeroChangesNothing() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 5), CGPoint(x: 2, y: 0)]
        XCTAssertEqual(PencilSmoothing.simplify(points, epsilon: 0), points)
    }

    func testItActuallyReducesARealisticStroke() {
        // The size claim: hundreds of samples become tens of stored points.
        let jittery = (0...400).map { index -> CGPoint in
            let t = Double(index)
            return CGPoint(x: t, y: t * 0.5 + sin(t / 7) * 0.4)   // a line with hand tremor
        }
        let simplified = PencilSmoothing.simplify(jittery, epsilon: 1.5)
        XCTAssertLessThan(simplified.count, 40)
        XCTAssertGreaterThan(simplified.count, 1)
    }

    func testTheCurvePassesThroughEveryInputPoint() {
        // Catmull-Rom rather than a plain Bézier precisely so the line goes where the hand went.
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 80),
                      CGPoint(x: 120, y: 20), CGPoint(x: 200, y: 100)]
        let curves = PencilSmoothing.catmullRomBeziers(points)
        XCTAssertEqual(curves.count, points.count - 1)
        for (index, curve) in curves.enumerated() {
            XCTAssertEqual(curve.from, points[index])
            XCTAssertEqual(curve.to, points[index + 1])
        }
    }

    func testASingleTapProducesADotRatherThanCrashing() {
        XCTAssertTrue(PencilSmoothing.catmullRomBeziers([CGPoint(x: 5, y: 5)]).isEmpty)
        XCTAssertEqual(PencilSmoothing.simplify([CGPoint(x: 5, y: 5)], epsilon: 1).count, 1)
        XCTAssertEqual(PencilSmoothing.polyline([CGPoint(x: 5, y: 5)]).count, 1)
    }

    func testTwoPointsAreASingleSegment() {
        let curves = PencilSmoothing.catmullRomBeziers([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        XCTAssertEqual(curves.count, 1)
    }
}

final class CanvasTransformTests: XCTestCase {

    func testViewAndImageRoundTrip() {
        let transform = CanvasTransform(imageSize: CGSize(width: 800, height: 600),
                                        zoom: 2.5, offset: CGPoint(x: 30, y: -12))
        let point = CGPoint(x: 123, y: 456)
        let round = transform.toImage(transform.toView(point))
        XCTAssertEqual(round.x, point.x, accuracy: 0.0001)
        XCTAssertEqual(round.y, point.y, accuracy: 0.0001)
    }

    func testToleranceIsAFixedPhysicalSize() {
        // A 6pt grab area must stay 6pt on screen: in image pixels it has to shrink as you zoom in.
        let zoomedIn = CanvasTransform(imageSize: .zero, zoom: 4)
        let zoomedOut = CanvasTransform(imageSize: .zero, zoom: 0.25)
        XCTAssertEqual(zoomedIn.imageTolerance(forViewTolerance: 6), 1.5)
        XCTAssertEqual(zoomedOut.imageTolerance(forViewTolerance: 6), 24)
    }

    func testFittingCentresTheImage() {
        let transform = CanvasTransform.fitting(imageSize: CGSize(width: 400, height: 200),
                                                in: CGSize(width: 800, height: 800))
        XCTAssertEqual(transform.zoom, 1, "a small image is not upscaled by default")
        XCTAssertEqual(transform.offset.x, 200)
        XCTAssertEqual(transform.offset.y, 300)
    }

    func testFittingShrinksAnImageLargerThanTheView() {
        let transform = CanvasTransform.fitting(imageSize: CGSize(width: 4000, height: 2000),
                                                in: CGSize(width: 800, height: 800))
        XCTAssertEqual(transform.zoom, 0.2, accuracy: 0.0001)
    }

    func testAZeroSizedViewDoesNotProduceAnInvalidTransform() {
        let transform = CanvasTransform.fitting(imageSize: CGSize(width: 100, height: 100),
                                                in: .zero)
        XCTAssertGreaterThan(transform.zoom, 0)
    }
}
