import CoreGraphics
import XCTest
@testable import Sarvkrit

final class SnapZoneTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func zone(_ x: CGFloat, _ y: CGFloat, in rect: CGRect? = nil) -> SnapZone? {
        SnapZoneLayout.zone(at: CGPoint(x: x, y: y), in: rect ?? screen)
    }

    // MARK: - Edges (Cocoa space: y=0 is the bottom)

    func testTheEdgesAreFound() {
        XCTAssertEqual(zone(800, 995), .top)
        XCTAssertEqual(zone(800, 5), .bottom)
        XCTAssertEqual(zone(5, 500), .left)
        XCTAssertEqual(zone(1595, 500), .right)
    }

    func testMostOfTheScreenIsNoZone() {
        // A window dragged across the middle must trigger nothing at all.
        XCTAssertNil(zone(800, 700))
        XCTAssertNil(zone(400, 300))
        XCTAssertNil(zone(1200, 800))
    }

    func testTheCentreIsASmallTargetNotEverythingInside() {
        XCTAssertEqual(zone(800, 500), .center)
        XCTAssertNil(zone(800, 620), "just outside the centre target is no zone, not centre")
    }

    // MARK: - Corners beat edges

    func testCornersWinOverTheEdgesTheyTouch() {
        // Aiming at a corner must not land on the edge beside it.
        XCTAssertEqual(zone(5, 995), .topLeft)
        XCTAssertEqual(zone(1595, 995), .topRight)
        XCTAssertEqual(zone(5, 5), .bottomLeft)
        XCTAssertEqual(zone(1595, 5), .bottomRight)
    }

    func testACornerIsReachableFromEitherOfItsEdges() {
        // Coming in along the top, and coming down the left side, both mean the same corner.
        XCTAssertEqual(zone(60, 995), .topLeft, "along the top edge")
        XCTAssertEqual(zone(5, 940), .topLeft, "down the left edge")
    }

    func testTheEdgeResumesPastTheCornerLength() {
        XCTAssertEqual(zone(200, 995), .top, "beyond the corner's reach")
        XCTAssertEqual(zone(5, 500), .left)
    }

    // MARK: - Boundaries

    func testTheEdgeBoundaryIsInclusive() {
        let thickness = SnapZoneLayout.edgeThickness
        XCTAssertEqual(zone(800, screen.maxY - thickness), .top)
        XCTAssertNil(zone(800, screen.maxY - thickness - 1), "one point further in is no zone")
    }

    func testAPointOutsideTheScreenIsNoZone() {
        XCTAssertNil(zone(-5, 500))
        XCTAssertNil(zone(2000, 500))
    }

    // MARK: - Flipped space

    func testFlippedSpacePutsTopAtMinY() {
        // `CGEvent.location` has its origin at the top-left, `NSScreen` at the bottom-left. Reading
        // a pointer in one space against a screen in the other mirrors every zone vertically —
        // "top" would snap to the bottom.
        let flipped = SnapZoneLayout.zone(at: CGPoint(x: 800, y: 5), in: screen, flipped: true)
        XCTAssertEqual(flipped, .top)

        let unflipped = SnapZoneLayout.zone(at: CGPoint(x: 800, y: 5), in: screen, flipped: false)
        XCTAssertEqual(unflipped, .bottom, "the same point means the opposite edge")
    }

    func testFlippedCornersMirrorToo() {
        XCTAssertEqual(SnapZoneLayout.zone(at: CGPoint(x: 5, y: 5), in: screen, flipped: true),
                       .topLeft)
        XCTAssertEqual(SnapZoneLayout.zone(at: CGPoint(x: 5, y: 5), in: screen, flipped: false),
                       .bottomLeft)
    }

    // MARK: - A second display

    func testZonesAreRelativeToTheScreenNotTheGlobalOrigin() {
        // A secondary display to the right: its left edge is at x=1600, not x=0. Testing against
        // the global origin would put every zone on the wrong monitor — invisible on this Mac.
        let second = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(zone(1605, 500, in: second), .left)
        XCTAssertEqual(zone(3195, 500, in: second), .right)
        XCTAssertNil(zone(5, 500, in: second), "a point on the primary is not in this screen")
    }

    // MARK: - Actions

    func testEveryZoneHasADefaultAction() {
        for zone in SnapZone.allCases {
            XCTAssertNotNil(SnapZoneLayout.defaultActions[zone], "\(zone.title) does nothing")
            XCTAssertNotNil(SnapZoneLayout.ultrawideActions[zone], "\(zone.title) on ultrawide")
        }
    }

    func testUltrawideEdgesGiveThirds() {
        XCTAssertEqual(SnapZoneLayout.defaultAction(for: .left, ultrawide: true), .firstThird)
        XCTAssertEqual(SnapZoneLayout.defaultAction(for: .right, ultrawide: true), .lastThird)
        XCTAssertEqual(SnapZoneLayout.defaultAction(for: .left, ultrawide: false), .leftHalf)
    }

    func testNoSnapZoneUsesAnActionThatCycles() {
        // The preview and the drop must agree. `leftHalf` on an ultrawide cycles third → half →
        // two-thirds from the window's *current* frame, so a footprint computed from it could show
        // one rect while the drop computed another.
        let cycling: Set<WindowAction> = [.leftHalf, .rightHalf]
        for (zone, action) in SnapZoneLayout.ultrawideActions {
            XCTAssertFalse(cycling.contains(action),
                           "\(zone.title) uses \(action.title), which cycles on an ultrawide")
        }
    }
}
