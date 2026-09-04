import XCTest
@testable import Sarvkrit

final class WindowListFilterTests: XCTestCase {

    private func window(_ id: CGWindowID, app: String?, title: String?) -> CapturableWindow {
        CapturableWindow(id: id, frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                         title: title, owningBundleID: nil, owningAppName: app,
                         layer: 0, isOnScreen: true)
    }

    private lazy var windows = [
        window(3, app: "Safari", title: "Invoices"),
        window(1, app: "Xcode", title: "Sarvkrit"),
        window(2, app: "safari", title: "Anthropic"),
        window(4, app: "Finder", title: nil),
    ]

    func testGroupedByApplicationThenTitle() {
        let ordered = WindowListFilter.ordered(windows)
        XCTAssertEqual(ordered.map { $0.owningAppName?.lowercased() },
                       ["finder", "safari", "safari", "xcode"])
        XCTAssertEqual(ordered[1].title, "Anthropic", "titles sort within an app")
        XCTAssertEqual(ordered[2].title, "Invoices")
    }

    func testTheOrderIsStableSoTheSelectionDoesNotMoveUnderTheArrowKeys() {
        let twins = [window(9, app: "Preview", title: nil), window(5, app: "Preview", title: nil)]
        XCTAssertEqual(WindowListFilter.ordered(twins).map(\.id), [5, 9])
        XCTAssertEqual(WindowListFilter.ordered(twins.reversed()).map(\.id), [5, 9])
    }

    func testTypingMatchesTheAppOrTheTitle() {
        XCTAssertEqual(WindowListFilter.matching("saf", in: windows).count, 2)
        XCTAssertEqual(WindowListFilter.matching("invoice", in: windows).map(\.id), [3])
        XCTAssertEqual(WindowListFilter.matching("SARVKRIT", in: windows).map(\.id), [1],
                       "matching is case-insensitive")
    }

    func testAnEmptyQueryShowsEverythingRatherThanNothing() {
        XCTAssertEqual(WindowListFilter.matching("", in: windows).count, windows.count)
        XCTAssertEqual(WindowListFilter.matching("   ", in: windows).count, windows.count)
    }

    func testAWindowWithNoTitleIsStillReachableByItsApp() {
        XCTAssertEqual(WindowListFilter.matching("finder", in: windows).map(\.id), [4])
    }

    func testMovingTheSelectionClampsRatherThanWraps() {
        // Wrapping means holding the down-arrow quietly returns you to the top, and Return then
        // captures a window you were not looking at.
        XCTAssertEqual(WindowListFilter.moving(from: 3, by: 1, count: 4), 3)
        XCTAssertEqual(WindowListFilter.moving(from: 0, by: -1, count: 4), 0)
        XCTAssertEqual(WindowListFilter.moving(from: 1, by: 2, count: 4), 3)
        XCTAssertEqual(WindowListFilter.moving(from: 0, by: 1, count: 0), 0, "an empty list")
    }
}

/// What belongs in a list, as opposed to what can be captured.
final class WindowListPresentableTests: XCTestCase {

    private func window(_ id: CGWindowID, app: String?, title: String?,
                        layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600))
        -> CapturableWindow {
        CapturableWindow(id: id, frame: CGRect(origin: .zero, size: size),
                         title: title, owningBundleID: nil, owningAppName: app,
                         layer: layer, isOnScreen: true)
    }

    func testTheSystemFurnitureTheFirstRunOfferedIsGone() {
        // Every one of these was above a real window in the list, which is not a list anybody
        // would use.
        let junk = [
            window(1, app: "Window Server", title: "Display 1 Backstop", layer: -2_147_483_603),
            window(2, app: "Window Server", title: "Menubar", layer: 24,
                   size: CGSize(width: 1512, height: 33)),
            window(3, app: "Control Centre", title: "StatusIndicator", layer: 25,
                   size: CGSize(width: 28, height: 29)),
            window(4, app: "Window Server", title: "underbelly", layer: 24,
                   size: CGSize(width: 1512, height: 83)),
        ]
        XCTAssertTrue(WindowListFilter.presentable(junk).isEmpty,
                      "still offering: \(WindowListFilter.presentable(junk).map { $0.title ?? "?" })")
    }

    func testRealWindowsSurvive() {
        let real = [window(10, app: "Safari", title: "Anthropic"),
                    window(11, app: "Xcode", title: "Sarvkrit")]
        XCTAssertEqual(WindowListFilter.presentable(real).count, 2)
    }

    func testASmallButGenuinePaletteIsKept() {
        let palette = window(12, app: "Preview", title: "Inspector",
                             size: CGSize(width: 260, height: 340))
        XCTAssertEqual(WindowListFilter.presentable([palette]).count, 1)
    }

    func testAWindowWithNoNamedOwnerIsDropped() {
        // A row with nothing to attribute it to is unreadable even when the window is genuine.
        XCTAssertTrue(WindowListFilter.presentable([window(13, app: nil, title: "Something")])
            .isEmpty)
        XCTAssertTrue(WindowListFilter.presentable([window(14, app: "", title: "Something")])
            .isEmpty)
    }

    func testHoverPickingIsNotNarrowedByThis() {
        // Pointing happens on a frozen screen, where whatever you point at is something you can
        // see. Narrowing that as well would make windows unpickable that are plainly there.
        let menubar = window(2, app: "Window Server", title: "Menubar", layer: 24,
                             size: CGSize(width: 1512, height: 33))
        let capturable = WindowPicker.capturable(from: [menubar], excludingBundleIDs: [],
                                                 desktopIconLayer: -2_147_483_603)
        XCTAssertEqual(capturable.count, 1)
    }
}
