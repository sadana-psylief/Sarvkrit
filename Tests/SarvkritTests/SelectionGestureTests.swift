import XCTest
@testable import Sarvkrit

/// The drag state machine. Every one of these is a way a selection can end that you would
/// otherwise only find by dragging on a real screen and looking closely.
final class SelectionGestureTests: XCTestCase {
    private let display = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        scale: 2, pixelSize: CGSize(width: 2000, height: 1600))

    private func gesture() -> SelectionGesture { SelectionGesture(display: display) }

    func testAnOrdinaryDragProducesTheRect() {
        var g = gesture()
        g.began(at: CGPoint(x: 100, y: 100))
        g.moved(to: CGPoint(x: 300, y: 250))
        XCTAssertEqual(g.ended(), CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testAClickWithNoDragSelectsNothing() {
        // Without the minimum distance this yields a 0x0 capture, which looks like a crash rather
        // than like nothing happened — and clicking to dismiss is a thing people do.
        var g = gesture()
        g.began(at: CGPoint(x: 500, y: 500))
        g.moved(to: CGPoint(x: 501, y: 501))
        XCTAssertNil(g.ended())
        XCTAssertNil(g.currentRect)
    }

    func testEscapeMidDragYieldsNothing() {
        var g = gesture()
        g.began(at: CGPoint(x: 100, y: 100))
        g.moved(to: CGPoint(x: 400, y: 400))
        g.cancel()
        XCTAssertTrue(g.isCancelled)
        XCTAssertNil(g.currentRect)
        XCTAssertNil(g.ended(), "a cancelled gesture must not still produce a rect")
    }

    func testADragThatLeavesTheDisplayIsClamped() {
        var g = gesture()
        g.began(at: CGPoint(x: 900, y: 700))
        g.moved(to: CGPoint(x: 1400, y: 1200))
        let rect = g.ended()
        XCTAssertEqual(rect?.maxX, 1000)
        XCTAssertEqual(rect?.maxY, 800)
    }

    func testDraggingBackwardsIsTheSameAsForwards() {
        var forward = gesture()
        forward.began(at: CGPoint(x: 100, y: 100))
        forward.moved(to: CGPoint(x: 300, y: 300))

        var backward = gesture()
        backward.began(at: CGPoint(x: 300, y: 300))
        backward.moved(to: CGPoint(x: 100, y: 100))

        XCTAssertEqual(forward.ended(), backward.ended())
    }

    func testAnAspectLockHoldsThroughTheDrag() {
        var g = gesture()
        g.aspectRatio = 16.0 / 9.0
        g.began(at: CGPoint(x: 100, y: 100))
        g.moved(to: CGPoint(x: 500, y: 200))
        let rect = try! XCTUnwrap(g.currentRect)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
    }

    func testNudgingMovesASettledSelection() {
        var g = gesture()
        g.began(at: CGPoint(x: 100, y: 100))
        g.moved(to: CGPoint(x: 300, y: 300))
        _ = g.ended()
        g.nudge(by: CGSize(width: 10, height: -5))
        XCTAssertEqual(g.currentRect, CGRect(x: 110, y: 95, width: 200, height: 200))
    }

    func testNudgingDoesNothingBeforeTheMouseIsUp() {
        var g = gesture()
        g.began(at: CGPoint(x: 100, y: 100))
        g.moved(to: CGPoint(x: 300, y: 300))
        let before = g.currentRect
        g.nudge(by: CGSize(width: 50, height: 50))
        XCTAssertEqual(g.currentRect, before)
    }

    func testNudgingAtAnEdgeStopsRatherThanShrinking() {
        // Intersecting with the display would shrink the selection at the edge, which reads as the
        // selection being eaten. Clamping the offset keeps the size.
        var g = gesture()
        g.began(at: CGPoint(x: 900, y: 700))
        g.moved(to: CGPoint(x: 1000, y: 800))
        _ = g.ended()
        let size = g.currentRect!.size
        g.nudge(by: CGSize(width: 500, height: 500))
        XCTAssertEqual(g.currentRect?.size, size)
        XCTAssertEqual(g.currentRect?.maxX, 1000)
    }

    func testTheReadoutIsInPixelsNotPoints() {
        var g = gesture()
        g.began(at: CGPoint(x: 0, y: 0))
        g.moved(to: CGPoint(x: 100, y: 50))
        XCTAssertEqual(g.pixelSize, CGSize(width: 200, height: 100))
    }

    func testATypedPixelSizeReplacesTheSelectionInPlace() {
        var g = gesture()
        g.began(at: CGPoint(x: 100, y: 100))
        g.moved(to: CGPoint(x: 300, y: 300))
        _ = g.ended()
        g.setPixelSize(CGSize(width: 800, height: 600))
        let rect = try! XCTUnwrap(g.currentRect)
        XCTAssertEqual(rect.width, 400)     // 800 px at 2x
        XCTAssertEqual(rect.height, 300)
        XCTAssertEqual(rect.midX, 200, "it should stay where it was")
        XCTAssertEqual(rect.midY, 200)
    }

    func testATypedSizeLargerThanTheDisplayIsClamped() {
        var g = gesture()
        g.setPixelSize(CGSize(width: 99_999, height: 99_999))
        let rect = try! XCTUnwrap(g.currentRect)
        XCTAssertLessThanOrEqual(rect.width, display.frame.width)
        XCTAssertLessThanOrEqual(rect.height, display.frame.height)
    }

    func testMovingBeforeBeginningIsIgnored() {
        var g = gesture()
        g.moved(to: CGPoint(x: 500, y: 500))
        XCTAssertNil(g.currentRect)
        XCTAssertFalse(g.isActive)
    }
}

/// Adjusting a selection after the drag, which is what makes one-shot accuracy unnecessary.
final class SelectionAdjustmentTests: XCTestCase {
    private let display = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        scale: 2, pixelSize: CGSize(width: 2000, height: 1600))

    private func settled(_ rect: CGRect) -> SelectionGesture {
        var gesture = SelectionGesture(display: display)
        gesture.began(at: CGPoint(x: rect.minX, y: rect.minY))
        gesture.moved(to: CGPoint(x: rect.maxX, y: rect.maxY))
        _ = gesture.ended()
        return gesture
    }

    func testADragLeavesTheSelectionSettledRatherThanFinished() {
        // It used to confirm on mouse-up, so there was no moment in which to adjust it.
        let gesture = settled(CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(gesture.settledRect, CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    func testAHandleResizesFromTheOppositeCorner() {
        var gesture = settled(CGRect(x: 100, y: 100, width: 200, height: 150))
        gesture.resize(handle: .bottomRight, to: CGPoint(x: 400, y: 400),
                       constrainAspect: false)
        let rect = try! XCTUnwrap(gesture.settledRect)
        XCTAssertEqual(rect.minX, 100)
        XCTAssertEqual(rect.maxX, 400)
    }

    func testResizingStaysInsideTheDisplay() {
        var gesture = settled(CGRect(x: 800, y: 700, width: 100, height: 50))
        gesture.resize(handle: .bottomRight, to: CGPoint(x: 5000, y: 5000),
                       constrainAspect: false)
        let rect = try! XCTUnwrap(gesture.settledRect)
        XCTAssertLessThanOrEqual(rect.maxX, display.frame.maxX)
        XCTAssertLessThanOrEqual(rect.maxY, display.frame.maxY)
    }

    func testAspectCanBeHeldWhileResizing() {
        var gesture = settled(CGRect(x: 100, y: 100, width: 200, height: 100))
        gesture.resize(handle: .bottomRight, to: CGPoint(x: 500, y: 130),
                       constrainAspect: true)
        let rect = try! XCTUnwrap(gesture.settledRect)
        XCTAssertEqual(rect.width / rect.height, 2, accuracy: 0.05)
    }

    func testResizingDoesNothingBeforeTheDragIsOver() {
        var gesture = SelectionGesture(display: display)
        gesture.began(at: CGPoint(x: 100, y: 100))
        gesture.moved(to: CGPoint(x: 200, y: 200))
        gesture.resize(handle: .bottomRight, to: CGPoint(x: 900, y: 900),
                       constrainAspect: false)
        XCTAssertNil(gesture.settledRect, "still dragging — there is nothing settled to resize")
    }

    func testNudgingStillWorksAfterAResize() {
        var gesture = settled(CGRect(x: 100, y: 100, width: 200, height: 150))
        gesture.resize(handle: .bottomRight, to: CGPoint(x: 350, y: 300),
                       constrainAspect: false)
        gesture.nudge(by: CGSize(width: 10, height: 0))
        XCTAssertEqual(gesture.settledRect?.minX, 110)
    }
}
