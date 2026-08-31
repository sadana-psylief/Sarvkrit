import CoreGraphics
import XCTest
@testable import Sarvkrit

/// A drag is close to untestable by hand — reproducing "released over the top-left corner" means
/// actually doing it, every time — so the whole sequence lives here instead.
final class SnapDragSessionTests: XCTestCase {

    private let start = CGPoint(x: 500, y: 500)
    private var far: CGPoint { CGPoint(x: 500, y: 600) }

    func testAPressAloneShowsNothing() {
        var session = SnapDragSession()
        XCTAssertNil(session.pressed(at: start))
    }

    func testASmallWobbleIsNotADrag() {
        // Clicking a titlebar always moves the pointer a little. Without a threshold, every click
        // would flash a footprint.
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        let barelyMoved = CGPoint(x: start.x + 2, y: start.y + 2)
        XCTAssertNil(session.moved(to: barelyMoved, zone: .left))
    }

    func testDraggingIntoAZoneShowsTheFootprint() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        XCTAssertEqual(session.moved(to: far, zone: .left), .showFootprint(.left))
    }

    func testMovingBetweenZonesMovesTheFootprint() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        _ = session.moved(to: far, zone: .left)
        XCTAssertEqual(session.moved(to: far, zone: .topLeft), .moveFootprint(.topLeft))
    }

    func testStayingInTheSameZoneRedrawsNothing() {
        // This fires at pointer frequency; re-emitting an effect per event would rebuild the
        // overlay a hundred times a second.
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        _ = session.moved(to: far, zone: .left)
        XCTAssertNil(session.moved(to: CGPoint(x: 501, y: 601), zone: .left))
    }

    func testLeavingEveryZoneHidesTheFootprint() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        _ = session.moved(to: far, zone: .left)
        XCTAssertEqual(session.moved(to: far, zone: nil), .hideFootprint)
    }

    func testDraggingThroughNoZoneShowsNothing() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        XCTAssertNil(session.moved(to: far, zone: nil))
    }

    // MARK: - Ending the drag

    func testReleasingInAZoneSnaps() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        _ = session.moved(to: far, zone: .topLeft)
        XCTAssertEqual(session.released(), .snap(.topLeft))
    }

    func testReleasingOutsideEveryZoneDoesNotSnap() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        _ = session.moved(to: far, zone: nil)
        XCTAssertNil(session.released(), "the window stays where the user dropped it")
    }

    func testAPlainClickSnapsNothing() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        XCTAssertNil(session.released())
    }

    func testCancellingMidDragHidesTheFootprintWithoutSnapping() {
        var session = SnapDragSession()
        _ = session.pressed(at: start)
        _ = session.moved(to: far, zone: .left)
        XCTAssertEqual(session.cancelled(), .hideFootprint)
    }

    func testEveryEndingLeavesTheSessionIdle() {
        // A session stuck armed would treat the next unrelated drag on the system as ours.
        for ending in ["release-in-zone", "release-outside", "cancel"] {
            var session = SnapDragSession()
            _ = session.pressed(at: start)
            _ = session.moved(to: far, zone: ending == "release-outside" ? nil : .left)
            _ = ending == "cancel" ? session.cancelled() : session.released()
            XCTAssertFalse(session.isArmed, "left armed after \(ending)")
        }
    }

    func testNoOverlayIsLeftBehindByAnyCancelPath() {
        // Cancelling while showing a footprint must hide it; cancelling when none is up must not
        // emit a stray hide.
        var showing = SnapDragSession()
        _ = showing.pressed(at: start)
        _ = showing.moved(to: far, zone: .left)
        XCTAssertEqual(showing.cancelled(), .hideFootprint)

        var notShowing = SnapDragSession()
        _ = notShowing.pressed(at: start)
        XCTAssertNil(notShowing.cancelled())
    }

    // MARK: - Other people's drags

    func testADragWeNeverArmedIsIgnored() {
        // `leftMouseDragged` fires for every drag on the system — selecting text, moving a file,
        // drawing in an app. Only a titlebar press arms us.
        var session = SnapDragSession()
        XCTAssertNil(session.moved(to: far, zone: .left))
        XCTAssertFalse(session.isArmed)
    }

    func testAReleaseWeNeverArmedSnapsNothing() {
        var session = SnapDragSession()
        XCTAssertNil(session.released())
    }

    func testAFreshSessionIsIdle() {
        XCTAssertFalse(SnapDragSession().isArmed)
        XCTAssertEqual(SnapDragSession().state, .idle)
    }
}
