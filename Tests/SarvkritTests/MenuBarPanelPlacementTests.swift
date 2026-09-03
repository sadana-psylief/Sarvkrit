import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The tray panel's anchoring. Pure, because the cases that matter — a second display, a screen
/// too short for the panel, an auto-hidden menu bar — cannot be reproduced on the machine running
/// the tests.
final class MenuBarPanelPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let width: CGFloat = 420
    /// Flush under a 25pt menu bar on a 1000-tall screen.
    private let menuBarBottom: CGFloat = 975

    // MARK: - The bug

    func testShrinkingThePanelLeavesItsTopEdgeWhereItWas() {
        // The reported bug, in numbers: switching Sound (1018pt) → Keyboard (693pt) moved the top
        // edge 178px down the screen. Both heights must put the top in the same place.
        let tall = MenuBarPanelPlacement.origin(
            forHeight: 700, x: 900, top: 975, width: width, in: visible)
        let short = MenuBarPanelPlacement.origin(
            forHeight: 400, x: 900, top: 975, width: width, in: visible)

        XCTAssertEqual(tall.y + 700, 975, "the top edge is the anchored edge")
        XCTAssertEqual(short.y + 400, 975, "and it does not move when the panel shrinks")
    }

    func testGrowingThePanelAlsoLeavesItsTopEdgeWhereItWas() {
        // Growing drifts the other way — Keyboard → Files — and is the same failure.
        for height in [200, 400, 600, 800] as [CGFloat] {
            let origin = MenuBarPanelPlacement.origin(
                forHeight: height, x: 900, top: 975, width: width, in: visible)
            XCTAssertEqual(origin.y + height, 975, "height \(height) moved the top edge")
        }
    }

    // MARK: - Clamping

    func testThePanelIsNeverPlacedUpUnderTheMenuBar() {
        // A stale anchor from a taller screen would ask for exactly this.
        let origin = MenuBarPanelPlacement.origin(
            forHeight: 400, x: 900, top: 1200, width: width, in: visible)
        XCTAssertEqual(origin.y + 400, visible.maxY)
    }

    func testATallPanelKeepsItsTopAndOverflowsTheBottom() {
        // Deliberate, and the reason there is no lower clamp: lifting a panel to fit would slide it
        // off the icon it belongs to, and far enough would tuck its header under the menu bar —
        // both worse than an overhang. Content this tall should scroll instead.
        for height in [990, 1200] as [CGFloat] {
            let origin = MenuBarPanelPlacement.origin(
                forHeight: height, x: 900, top: 975, width: width, in: visible)
            XCTAssertEqual(origin.y + height, 975, "height \(height) moved the top edge")
        }
    }

    func testTheHorizontalPositionIsPassedThroughUntouched() {
        // Regression guard: the horizontal position is the system's and was measured correct.
        // Deriving it is what would unmoor the panel sideways.
        for height in [200, 700, 1200] as [CGFloat] {
            let origin = MenuBarPanelPlacement.origin(
                forHeight: height, x: 900, top: 975, width: width, in: visible)
            XCTAssertEqual(origin.x, 900, "height \(height) moved the panel sideways")
        }
    }

    func testAPanelNearTheRightEdgeIsPulledBackOnScreen() {
        // A status item at the far right of the menu bar.
        let origin = MenuBarPanelPlacement.origin(
            forHeight: 400, x: 1500, top: 975, width: width, in: visible)
        XCTAssertEqual(origin.x + width, visible.maxX)
    }

    func testAnchoringWorksOnADisplayThatDoesNotStartAtZero() {
        // The case a single-display machine can never exercise: "the top of the screen" is not
        // 1000 and "the left edge" is not 0.
        let second = CGRect(x: 1600, y: -200, width: 1600, height: 1000)
        let origin = MenuBarPanelPlacement.origin(
            forHeight: 400, x: 2500, top: 775, width: width, in: second)
        XCTAssertEqual(origin.y + 400, 775)
        XCTAssertEqual(origin.x, 2500)
        XCTAssertGreaterThanOrEqual(origin.y, second.minY)
    }

    // MARK: - Trusting a captured anchor

    func testAFrameNowhereNearTheMenuBarIsNotAnAnchor() {
        // The frame the window carries before the system positions it. Capturing that would pin
        // the panel to the middle of the screen for the rest of the presentation.
        XCTAssertFalse(
            MenuBarPanelPlacement.isPlausibleAnchor(top: 500, menuBarBottom: menuBarBottom))
    }

    func testAFrameFlushUnderTheMenuBarIsAnAnchor() {
        XCTAssertTrue(
            MenuBarPanelPlacement.isPlausibleAnchor(top: 975, menuBarBottom: menuBarBottom))
        XCTAssertTrue(
            MenuBarPanelPlacement.isPlausibleAnchor(top: 973, menuBarBottom: menuBarBottom),
            "a couple of points of gap is what the system itself leaves")
    }

    func testATopHalfTheScreenAwayIsRejected() {
        // Generous is not credulous: a window parked in the middle of the screen is not an anchor.
        XCTAssertFalse(
            MenuBarPanelPlacement.isPlausibleAnchor(top: 500, menuBarBottom: menuBarBottom))
        XCTAssertFalse(
            MenuBarPanelPlacement.isPlausibleAnchor(top: 825, menuBarBottom: menuBarBottom))
    }

    func testAnAutoHiddenMenuBarStillHasAPlausibleAnchor() {
        // With auto-hide on, `visibleFrame.maxY` becomes the top of the screen while the system
        // still places the panel below the bar it is showing — measured ~33pt, where the normal
        // gap is 2pt. The tolerance has to cover that, or the anchor is thrown away in a setting
        // nobody thinks to test.
        XCTAssertTrue(
            MenuBarPanelPlacement.isPlausibleAnchor(top: visible.maxY - 33, menuBarBottom: visible.maxY))
    }

    // MARK: - Not moving

    func testSubPixelDifferencesAreNotWorthAMove() {
        let here = CGPoint(x: 900, y: 575)
        XCTAssertFalse(
            MenuBarPanelPlacement.needsMove(from: here, to: CGPoint(x: 900.4, y: 575)))
        XCTAssertTrue(
            MenuBarPanelPlacement.needsMove(from: here, to: CGPoint(x: 900, y: 575.6)))
    }
}
