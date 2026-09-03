import XCTest
@testable import Sarvkrit

/// The pointer always comes back.
///
/// A capture overlay that leaves the cursor hidden is the worst thing this feature could do to
/// somebody — there is no pointer to click "quit" with. So the balance is a test, not a habit.
@MainActor
final class OverlayCursorTests: XCTestCase {

    override func tearDown() async throws {
        OverlayCursor.show()
    }

    func testHidingThenShowingBalances() {
        OverlayCursor.hide()
        XCTAssertTrue(OverlayCursor.isHidden)
        OverlayCursor.show()
        XCTAssertFalse(OverlayCursor.isHidden)
    }

    func testHidingTwiceStillTakesOneShowToUndo() {
        // CGDisplayHideCursor is reference counted. Two hides and one show would leave the
        // pointer gone, which is why the flag guards the call rather than the caller having to.
        OverlayCursor.hide()
        OverlayCursor.hide()
        OverlayCursor.show()
        XCTAssertFalse(OverlayCursor.isHidden)
    }

    func testShowingWithoutHidingIsHarmless() {
        // The escape hatch calls `show()` unconditionally, including when no overlay was up.
        // An unbalanced show would push the reference count negative and hide the cursor for
        // everyone else on the system.
        OverlayCursor.show()
        OverlayCursor.show()
        XCTAssertFalse(OverlayCursor.isHidden)
    }

    func testTheEscapeHatchRestoresIt() {
        OverlayCursor.hide()
        CaptureOverlayGuard.shared.dismissEverything()
        XCTAssertFalse(OverlayCursor.isHidden, "⌃⇧⎋ must give the pointer back")
    }
}
