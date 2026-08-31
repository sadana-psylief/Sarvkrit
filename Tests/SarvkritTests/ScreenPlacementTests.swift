import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Panel placement and edge detection. Pure, because the multi-display cases can't be checked on a
/// single-display machine — the same reason the window feature's geometry is pure.
final class ScreenPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let size = CGSize(width: 300, height: 400)

    // MARK: - Clamping

    func testAPanelInTheMiddleIsPlacedJustOffThePointer() {
        let origin = ScreenPlacement.topLeft(forSize: size, at: CGPoint(x: 800, y: 500), in: visible)
        XCTAssertEqual(origin, CGPoint(x: 808, y: 492), "offset so it doesn't open under the pointer")
    }

    func testAPanelNearTheRightEdgeFlipsToTheLeft() {
        let origin = ScreenPlacement.topLeft(forSize: size, at: CGPoint(x: 1580, y: 500), in: visible)
        XCTAssertLessThan(origin.x, 1580, "it should open leftward rather than off-screen")
        XCTAssertGreaterThanOrEqual(origin.x, visible.minX)
        XCTAssertLessThanOrEqual(origin.x + size.width, visible.maxX)
    }

    func testAPanelNearTheBottomFlipsUpward() {
        // `y` is the top edge, so the panel extends downward — near the bottom it must flip.
        let origin = ScreenPlacement.topLeft(forSize: size, at: CGPoint(x: 800, y: 20), in: visible)
        XCTAssertGreaterThan(origin.y, 20)
        XCTAssertLessThanOrEqual(origin.y, visible.maxY)
    }

    func testAPanelNeverOpensAboveTheVisibleArea() {
        // The menu bar is exactly where a pointer often is.
        let origin = ScreenPlacement.topLeft(forSize: size, at: CGPoint(x: 800, y: 995), in: visible)
        XCTAssertLessThanOrEqual(origin.y, visible.maxY)
    }

    func testClampingWorksOnASecondDisplayThatDoesNotStartAtZero() {
        // The case a single-display machine can never show: a screen whose origin isn't (0,0).
        let second = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
        let origin = ScreenPlacement.topLeft(forSize: size, at: CGPoint(x: 3180, y: 500), in: second)
        XCTAssertGreaterThanOrEqual(origin.x, second.minX)
        XCTAssertLessThanOrEqual(origin.x + size.width, second.maxX)
    }

    // MARK: - Edges

    func testEachEdgeIsDetected() {
        XCTAssertEqual(ScreenPlacement.edge(at: CGPoint(x: 2, y: 500), in: visible, thickness: 6), .left)
        XCTAssertEqual(ScreenPlacement.edge(at: CGPoint(x: 1598, y: 500), in: visible, thickness: 6), .right)
        XCTAssertEqual(ScreenPlacement.edge(at: CGPoint(x: 800, y: 998), in: visible, thickness: 6), .top)
        XCTAssertEqual(ScreenPlacement.edge(at: CGPoint(x: 800, y: 2), in: visible, thickness: 6), .bottom)
    }

    func testTheMiddleOfTheScreenIsNoEdge() {
        XCTAssertNil(ScreenPlacement.edge(at: CGPoint(x: 800, y: 500), in: visible, thickness: 6))
    }

    func testAPointOutsideTheScreenIsNoEdge() {
        XCTAssertNil(ScreenPlacement.edge(at: CGPoint(x: -5, y: 500), in: visible, thickness: 6))
    }

    func testEdgesAreRelativeToTheScreenNotTheGlobalOrigin() {
        // On a second display to the right, "the left edge" is x == 1600, not x == 0.
        let second = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
        XCTAssertEqual(ScreenPlacement.edge(at: CGPoint(x: 1602, y: 500), in: second, thickness: 6), .left)
        XCTAssertNil(ScreenPlacement.edge(at: CGPoint(x: 2, y: 500), in: second, thickness: 6),
                     "a point on the primary is not on this screen at all")
    }

    // MARK: - Strips

    func testAStripHugsItsEdgeAndSpansTheScreen() {
        let left = ScreenPlacement.strip(for: .left, in: visible, thickness: 6)
        XCTAssertEqual(left, CGRect(x: 0, y: 0, width: 6, height: 1000))

        let top = ScreenPlacement.strip(for: .top, in: visible, thickness: 6)
        XCTAssertEqual(top, CGRect(x: 0, y: 994, width: 1600, height: 6))
    }

    func testEveryStripLiesInsideItsScreen() {
        let second = CGRect(x: 1600, y: -200, width: 1600, height: 1000)
        for edge in ScreenPlacement.Edge.allCases {
            let strip = ScreenPlacement.strip(for: edge, in: second, thickness: 8)
            XCTAssertTrue(second.contains(strip), "\(edge.title) strip escaped its screen")
        }
    }

    func testEveryEdgeHasATitle() {
        for edge in ScreenPlacement.Edge.allCases {
            XCTAssertFalse(edge.title.isEmpty)
        }
    }
}
