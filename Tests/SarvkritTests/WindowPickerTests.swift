import XCTest
@testable import Sarvkrit

final class WindowPickerTests: XCTestCase {
    private let iconLayer = -2_147_483_603

    private func window(_ id: CGWindowID, _ rect: CGRect,
                        bundle: String? = "com.example.app",
                        layer: Int = 0,
                        onScreen: Bool = true) -> CapturableWindow {
        CapturableWindow(id: id, frame: rect, title: "w\(id)",
                         owningBundleID: bundle, owningAppName: "App",
                         layer: layer, isOnScreen: onScreen)
    }

    // MARK: - Filtering

    func testOurOwnWindowsAreNeverCapturable() {
        // The capture overlay is on screen at the exact moment this runs, and it covers
        // everything — without this every window hover would pick Sarvkrit.
        let windows = [window(1, CGRect(x: 0, y: 0, width: 100, height: 100),
                              bundle: AppIdentity.bundleID),
                       window(2, CGRect(x: 0, y: 0, width: 100, height: 100))]
        let result = WindowPicker.capturable(from: windows,
                                             excludingBundleIDs: [AppIdentity.bundleID],
                                             desktopIconLayer: iconLayer)
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testDesktopIconWindowsAreNeverCapturable() {
        // The desktop covers the whole screen, so it would swallow every hover that missed.
        let windows = [window(1, CGRect(x: 0, y: 0, width: 2000, height: 2000), layer: iconLayer),
                       window(2, CGRect(x: 10, y: 10, width: 100, height: 100))]
        let result = WindowPicker.capturable(from: windows, excludingBundleIDs: [],
                                             desktopIconLayer: iconLayer)
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testZeroSizeAndOffscreenWindowsAreSkipped() {
        let windows = [window(1, .zero),
                       window(2, CGRect(x: 0, y: 0, width: 1, height: 1)),
                       window(3, CGRect(x: 0, y: 0, width: 100, height: 100), onScreen: false),
                       window(4, CGRect(x: 0, y: 0, width: 100, height: 100))]
        let result = WindowPicker.capturable(from: windows, excludingBundleIDs: [],
                                             desktopIconLayer: iconLayer)
        XCTAssertEqual(result.map(\.id), [4])
    }

    func testFilteringPreservesFrontToBackOrder() {
        // SCShareableContent hands them over front-to-back and z-order is not derivable from a
        // frame, so re-sorting here would throw away the only depth information there is.
        let windows = (1...5).map { window(CGWindowID($0),
                                           CGRect(x: 0, y: 0, width: 100, height: 100)) }
        let result = WindowPicker.capturable(from: windows, excludingBundleIDs: [],
                                             desktopIconLayer: iconLayer)
        XCTAssertEqual(result.map(\.id), [1, 2, 3, 4, 5])
    }

    // MARK: - Hit testing

    func testAPointOutsideEveryWindowPicksNothing() {
        let windows = [window(1, CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertNil(WindowPicker.window(at: CGPoint(x: 500, y: 500), in: windows))
    }

    func testTheFrontmostOverlappingWindowWins() {
        let front = window(1, CGRect(x: 0, y: 0, width: 200, height: 200))
        let back = window(2, CGRect(x: 50, y: 50, width: 200, height: 200))
        XCTAssertEqual(WindowPicker.window(at: CGPoint(x: 100, y: 100),
                                           in: [front, back])?.id, 1)
    }

    func testASheetInsideItsParentIsPreferredOverIt() {
        // A small window fully inside a large one — a sheet, a palette — is what is being aimed at.
        let parent = window(1, CGRect(x: 0, y: 0, width: 800, height: 600))
        let sheet = window(2, CGRect(x: 300, y: 250, width: 200, height: 100))
        XCTAssertEqual(WindowPicker.window(at: CGPoint(x: 350, y: 280),
                                           in: [parent, sheet])?.id, 2)
    }

    func testASheetIsOnlyPreferredWhereItActuallyIs() {
        let parent = window(1, CGRect(x: 0, y: 0, width: 800, height: 600))
        let sheet = window(2, CGRect(x: 300, y: 250, width: 200, height: 100))
        XCTAssertEqual(WindowPicker.window(at: CGPoint(x: 50, y: 50),
                                           in: [parent, sheet])?.id, 1)
    }

    func testTwoSideBySideWindowsDoNotSwapPriorityBySize() {
        // Only *containment* promotes a smaller window. Otherwise a small window merely
        // overlapping a big one would steal hits that belong to the front one.
        let front = window(1, CGRect(x: 0, y: 0, width: 400, height: 400))
        let smallOverlapping = window(2, CGRect(x: 300, y: 300, width: 200, height: 200))
        XCTAssertEqual(WindowPicker.window(at: CGPoint(x: 350, y: 350),
                                           in: [front, smallOverlapping])?.id, 1)
    }

    func testTheSmallestOfSeveralNestedWindowsWins() {
        let outer = window(1, CGRect(x: 0, y: 0, width: 800, height: 600))
        let middle = window(2, CGRect(x: 100, y: 100, width: 400, height: 300))
        let inner = window(3, CGRect(x: 200, y: 200, width: 100, height: 80))
        XCTAssertEqual(WindowPicker.window(at: CGPoint(x: 250, y: 240),
                                           in: [outer, middle, inner])?.id, 3)
    }

    func testAnEmptyListPicksNothing() {
        XCTAssertNil(WindowPicker.window(at: .zero, in: []))
    }
}
