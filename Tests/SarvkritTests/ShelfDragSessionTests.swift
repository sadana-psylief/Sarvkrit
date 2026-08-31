import XCTest
@testable import Sarvkrit

/// When a system-wide drag starts and stops.
///
/// This exists because the AppKit half can't be tested at all, and the previous attempt at drag
/// detection shipped on an assumption that was simply wrong. Everything checkable is checked here.
final class ShelfDragSessionTests: XCTestCase {

    private func session(startingAt changeCount: Int = 100) -> ShelfDragSession {
        var session = ShelfDragSession()
        session.begin(withChangeCount: changeCount)
        return session
    }

    func testABumpedChangeCountBeginsADrag() {
        var s = session(startingAt: 100)
        XCTAssertEqual(s.handle(.mouseDragged(changeCount: 101)), .dragBegan)
        XCTAssertTrue(s.isInProgress)
    }

    func testAStaleChangeCountDoesNotBeginADrag() {
        // The case that matters most. The last drag's contents stay on that pasteboard
        // indefinitely, so an unchanged count means the mouse is moving for some other reason —
        // selecting text, moving a window — and the shelf must not appear.
        var s = session(startingAt: 100)
        XCTAssertNil(s.handle(.mouseDragged(changeCount: 100)))
        XCTAssertFalse(s.isInProgress)
    }

    func testRepeatedDragsWithinOneSessionReportNothing() {
        // `leftMouseDragged` fires at pointer frequency; only the first is news.
        var s = session(startingAt: 100)
        XCTAssertEqual(s.handle(.mouseDragged(changeCount: 101)), .dragBegan)
        for _ in 0..<20 {
            XCTAssertNil(s.handle(.mouseDragged(changeCount: 101)))
        }
    }

    func testACountThatChangesMidDragDoesNotRestartIt() {
        // Some sources rewrite the pasteboard during a session; that is still one drag.
        var s = session(startingAt: 100)
        _ = s.handle(.mouseDragged(changeCount: 101))
        XCTAssertNil(s.handle(.mouseDragged(changeCount: 102)))
    }

    func testMouseUpEndsTheDrag() {
        var s = session(startingAt: 100)
        _ = s.handle(.mouseDragged(changeCount: 101))
        XCTAssertEqual(s.handle(.mouseUp), .dragEnded)
        XCTAssertFalse(s.isInProgress)
    }

    func testMouseUpWithNoDragInProgressIsInert() {
        // An ordinary click anywhere on the Mac arrives here; it must produce nothing.
        var s = session(startingAt: 100)
        XCTAssertNil(s.handle(.mouseUp))
    }

    func testASecondDragIsRecognisedAfterTheFirstEnds() {
        var s = session(startingAt: 100)
        _ = s.handle(.mouseDragged(changeCount: 101))
        _ = s.handle(.mouseUp)
        XCTAssertEqual(s.handle(.mouseDragged(changeCount: 102)), .dragBegan)
    }

    func testASecondDragWithTheSameCountIsNotRecognised() {
        // After a drag ends, its count is the baseline — moving the mouse again must not re-open
        // the shelf off the same stale pasteboard.
        var s = session(startingAt: 100)
        _ = s.handle(.mouseDragged(changeCount: 101))
        _ = s.handle(.mouseUp)
        XCTAssertNil(s.handle(.mouseDragged(changeCount: 101)))
    }

    func testTheBaselineStopsAPreExistingDragFromCounting() {
        // Switching the Shelf on shouldn't make the last drag of ten minutes ago look new.
        var s = ShelfDragSession()
        s.begin(withChangeCount: 500)
        XCTAssertNil(s.handle(.mouseDragged(changeCount: 500)))
    }

    func testWithoutABaselineTheFirstDragStillCounts() {
        // A fresh session with no baseline: the first bump is genuinely the first thing seen.
        var s = ShelfDragSession()
        XCTAssertEqual(s.handle(.mouseDragged(changeCount: 1)), .dragBegan)
    }

    func testResetForgetsAnInProgressDrag() {
        var s = session(startingAt: 100)
        _ = s.handle(.mouseDragged(changeCount: 101))
        s.reset()
        XCTAssertFalse(s.isInProgress)
        XCTAssertNil(s.handle(.mouseUp), "a mouse-up after switching off must report nothing")
    }
}
