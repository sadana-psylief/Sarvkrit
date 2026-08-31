import XCTest
@testable import Sarvkrit

/// This Mac has **one display**, so every multi-monitor bug here is invisible in manual testing.
/// These synthetic arrangements are the only defence against the classic failure: windows landing
/// mirrored vertically, or on the wrong screen entirely.
final class ScreenCoordinatesTests: XCTestCase {
    private let primaryHeight: CGFloat = 1000

    // MARK: - The flip

    func testConversionInvertsItself() {
        let rect = CGRect(x: 120, y: 240, width: 400, height: 300)
        let there = ScreenCoordinates.toAccessibility(rect, primaryHeight: primaryHeight)
        let back = ScreenCoordinates.toCocoa(there, primaryHeight: primaryHeight)
        XCTAssertEqual(back, rect)
    }

    func testAWindowAtTheBottomInCocoaIsAtTheBottomInAccessibility() {
        // Cocoa y=0 is the bottom; in AX that's the largest y. Getting this backwards mirrors
        // every window vertically.
        let atBottom = CGRect(x: 0, y: 0, width: 100, height: 200)
        let ax = ScreenCoordinates.toAccessibility(atBottom, primaryHeight: primaryHeight)
        XCTAssertEqual(ax.minY, primaryHeight - 200)
    }

    func testAWindowAtTheTopInCocoaIsAtOriginInAccessibility() {
        let atTop = CGRect(x: 0, y: primaryHeight - 200, width: 100, height: 200)
        XCTAssertEqual(ScreenCoordinates.toAccessibility(atTop, primaryHeight: primaryHeight).minY, 0)
    }

    func testXIsNeverTouched() {
        let rect = CGRect(x: -500, y: 100, width: 200, height: 200)
        XCTAssertEqual(ScreenCoordinates.toAccessibility(rect, primaryHeight: primaryHeight).minX, -500)
    }

    func testTheFlipUsesThePrimaryHeightNotTheTargetScreens() {
        // The sub-bug inside the bug. A window on a *taller* secondary display must still be
        // converted using the primary's height. Using the target's height is correct by accident
        // on a one-screen Mac and wrong the instant a second monitor appears.
        let onTallSecondary = CGRect(x: 2000, y: 100, width: 400, height: 300)

        let correct = ScreenCoordinates.toAccessibility(onTallSecondary, primaryHeight: 1000)
        let wrong = ScreenCoordinates.toAccessibility(onTallSecondary, primaryHeight: 1440)

        XCTAssertEqual(correct.minY, 1000 - 400)
        XCTAssertNotEqual(correct.minY, wrong.minY,
                          "if these matched, the test couldn't detect the mistake it exists for")
    }

    // MARK: - Which screen a window is on

    private let left = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let right = CGRect(x: 1600, y: 0, width: 1600, height: 1000)

    func testAWindowIsAssignedToTheScreenItSitsOn() {
        let onRight = CGRect(x: 2000, y: 100, width: 400, height: 300)
        XCTAssertEqual(ScreenCoordinates.screen(containing: onRight, screens: [left, right]), right)
    }

    func testAStraddlingWindowGoesToWhicheverShowsMoreOfIt() {
        // 300pt on the left screen, 100pt on the right.
        let straddling = CGRect(x: 1300, y: 100, width: 400, height: 300)
        XCTAssertEqual(ScreenCoordinates.screen(containing: straddling, screens: [left, right]), left)
    }

    func testAWindowOnNoScreenFallsBackToTheFirst() {
        // Dragged off-screen, or a display unplugged mid-drag.
        let nowhere = CGRect(x: 99_000, y: 99_000, width: 100, height: 100)
        XCTAssertEqual(ScreenCoordinates.screen(containing: nowhere, screens: [left, right]), left)
        XCTAssertNil(ScreenCoordinates.screen(containing: nowhere, screens: []))
    }

    func testScreensStackedVerticallyAreDistinguished() {
        let below = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let above = CGRect(x: 0, y: 1000, width: 1600, height: 1000)
        let up = CGRect(x: 100, y: 1200, width: 200, height: 200)
        XCTAssertEqual(ScreenCoordinates.screen(containing: up, screens: [below, above]), above)
    }

    // MARK: - Moving between displays

    func testNextDisplayWrapsAround() {
        XCTAssertEqual(ScreenCoordinates.adjacentScreen(to: left, screens: [left, right], forward: true), right)
        XCTAssertEqual(ScreenCoordinates.adjacentScreen(to: right, screens: [left, right], forward: true), left)
        XCTAssertEqual(ScreenCoordinates.adjacentScreen(to: left, screens: [left, right], forward: false), right)
    }

    func testASingleDisplayHasNoNextScreen() {
        // This Mac's actual situation — the action must do nothing rather than misbehave.
        XCTAssertNil(ScreenCoordinates.adjacentScreen(to: left, screens: [left], forward: true))
    }

    func testMovingBetweenDisplaysKeepsRelativePositionAndProportion() {
        // Displays differ in resolution: a window filling half of a small screen should fill half
        // of the big one, not keep its pixel size and look tiny.
        let small = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let big = CGRect(x: 1600, y: 0, width: 3200, height: 2000)
        let halfOfSmall = CGRect(x: 0, y: 0, width: 800, height: 1000)

        let moved = ScreenCoordinates.translate(halfOfSmall, from: small, to: big)

        XCTAssertEqual(moved.minX, big.minX)
        XCTAssertEqual(moved.width, big.width / 2, accuracy: 0.01)
        XCTAssertEqual(moved.height, big.height, accuracy: 0.01)
    }

    func testTranslateSurvivesADegenerateSourceScreen() {
        let zero = CGRect.zero
        let rect = CGRect(x: 10, y: 10, width: 100, height: 100)
        XCTAssertEqual(ScreenCoordinates.translate(rect, from: zero, to: left), rect)
    }
}
