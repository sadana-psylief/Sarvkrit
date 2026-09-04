import XCTest
@testable import Sarvkrit

/// Where the action bar lands.
///
/// The bar is the thing that tells you what to do next, so a bar that is off the screen is worse
/// than no bar: the flow looks broken rather than unfinished.
final class SelectionBarPlacementTests: XCTestCase {

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let bar = CGSize(width: 420, height: 44)

    private func place(_ selection: CGRect, on display: CGRect? = nil)
        -> SelectionBarPlacement.Result {
        SelectionBarPlacement.place(selection: selection, barSize: bar,
                                    display: display ?? self.display)
    }

    func testItSitsBelowTheSelectionCentredOnIt() {
        let selection = CGRect(x: 500, y: 400, width: 300, height: 200)
        let result = place(selection)
        XCTAssertEqual(result.position, .below)
        XCTAssertEqual(result.origin.y, 400 - 12 - 44, accuracy: 0.01)
        XCTAssertEqual(result.origin.x + bar.width / 2, selection.midX, accuracy: 0.01)
    }

    func testItFlipsAboveWhenTheSelectionIsAgainstTheBottom() {
        // Selecting something near the Dock is ordinary, and the bar must not go under the floor.
        let result = place(CGRect(x: 500, y: 10, width: 300, height: 200))
        XCTAssertEqual(result.position, .above)
        XCTAssertEqual(result.origin.y, 210 + 12, accuracy: 0.01)
    }

    func testItGoesInsideWhenTheSelectionFillsTheDisplay() {
        let result = place(CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(result.position, .inside, "overlapping the shot beats being unreachable")
        XCTAssertGreaterThanOrEqual(result.origin.y, 0)
        XCTAssertLessThanOrEqual(result.origin.y + bar.height, 982)
    }

    func testItNeverLeavesTheDisplayHorizontally() {
        for selection in [CGRect(x: -40, y: 400, width: 120, height: 100),
                          CGRect(x: 1450, y: 400, width: 120, height: 100),
                          CGRect(x: 0, y: 400, width: 1512, height: 100)] {
            let result = place(selection)
            XCTAssertGreaterThanOrEqual(result.origin.x, display.minX + 8 - 0.01,
                                        "ran off the left for \(selection)")
            XCTAssertLessThanOrEqual(result.origin.x + bar.width, display.maxX - 8 + 0.01,
                                     "ran off the right for \(selection)")
        }
    }

    func testItWorksOnADisplayWithANegativeOrigin() {
        // A second monitor to the left has negative coordinates, and this is the class of bug
        // `CaptureGeometryTests` exists for — invisible on a one-screen Mac.
        let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let result = place(CGRect(x: -1800, y: 500, width: 300, height: 200), on: secondary)
        XCTAssertEqual(result.position, .below)
        XCTAssertGreaterThanOrEqual(result.origin.x, secondary.minX + 8 - 0.01)
        XCTAssertLessThanOrEqual(result.origin.x + bar.width, secondary.maxX - 8 + 0.01)
    }

    func testABarWiderThanTheDisplayIsPinnedRatherThanNaN() {
        let narrow = CGRect(x: 0, y: 0, width: 300, height: 400)
        let result = SelectionBarPlacement.place(
            selection: CGRect(x: 20, y: 200, width: 100, height: 60),
            barSize: CGSize(width: 420, height: 44), display: narrow)
        XCTAssertEqual(result.origin.x, 8, accuracy: 0.01)
        XCTAssertFalse(result.origin.x.isNaN)
    }
}
