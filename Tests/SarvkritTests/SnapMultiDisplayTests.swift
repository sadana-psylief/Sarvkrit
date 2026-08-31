import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Dragging to an edge with two displays attached — a laptop alongside an ultrawide.
///
/// None of this can be seen on this Mac, which has one non-ultrawide display. Both bugs these tests
/// pin were written and shipped-to-branch before being caught by review, and both would have looked
/// perfectly correct here.
final class SnapMultiDisplayTests: XCTestCase {

    /// Laptop is primary at the origin; the ultrawide sits to its right.
    private let laptop = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let ultrawide = CGRect(x: 1600, y: 0, width: 3840, height: 1080)
    private var screens: [CGRect] { [laptop, ultrawide] }
    private var primaryHeight: CGFloat { laptop.height }

    private func resolve(_ x: CGFloat, _ y: CGFloat) -> (zone: SnapZone, screen: CGRect)? {
        // Pointer coordinates are in Accessibility space: origin top-left of the primary display.
        SnapZoneLayout.resolve(at: CGPoint(x: x, y: y), screenFrames: screens,
                               primaryHeight: primaryHeight)
    }

    // MARK: - Which screen the pointer is over

    func testAPointerOnTheLaptopResolvesToTheLaptop() {
        XCTAssertEqual(resolve(5, 500)?.screen, laptop)
        XCTAssertEqual(resolve(5, 500)?.zone, .left)
    }

    func testAPointerOnTheSecondDisplayResolvesToThatDisplay() {
        // x=1605 is 5 points into the ultrawide, i.e. its own left edge — not the laptop's.
        XCTAssertEqual(resolve(1605, 500)?.screen, ultrawide)
        XCTAssertEqual(resolve(1605, 500)?.zone, .left)
    }

    func testTheSecondDisplaysRightEdgeIsFoundAtItsOwnFarSide() {
        XCTAssertEqual(resolve(5435, 500)?.screen, ultrawide)
        XCTAssertEqual(resolve(5435, 500)?.zone, .right)
    }

    func testAPointerOnNoDisplayResolvesToNothing() {
        XCTAssertNil(resolve(9000, 500))
    }

    // MARK: - The flip, per display

    func testTopMeansTopOnEachDisplaysOwnTerms() {
        // The pointer arrives in top-left-origin space while screen frames are bottom-left. Get it
        // wrong and "top" snaps to the bottom.
        //
        // The two displays do *not* share a top edge. The ultrawide is 1080 tall against the
        // laptop's 1000 and both sit at Cocoa y=0, so in AX space the laptop spans 0…1000 while the
        // ultrawide spans −80…1000: its top edge is 80 points *above* the origin. A flip that used
        // the target screen's height instead of the primary's would put it at 0 and the top edge
        // would be unreachable.
        XCTAssertEqual(resolve(800, 5)?.zone, .top, "laptop top edge, at AX y=0")
        XCTAssertEqual(resolve(3500, -75)?.zone, .top, "ultrawide top edge, at AX y=-80")
        XCTAssertEqual(resolve(3500, -75)?.screen, ultrawide)
    }

    func testThePointOfTheLaptopsTopEdgeIsNotTheUltrawidesTopEdge() {
        // Same y, different displays, different answers — which is the whole point of resolving
        // per screen. On the ultrawide, AX y=5 is 85 points down from its top: no zone at all.
        XCTAssertEqual(resolve(800, 5)?.zone, .top)
        XCTAssertNil(resolve(3500, 5)?.zone, "well inside the ultrawide, not on any edge")
    }

    func testTheSharedBottomEdgeIsFoundOnBothDisplays() {
        // Both screens sit on Cocoa y=0, so both bottom edges are at AX y=1000.
        XCTAssertEqual(resolve(800, 995)?.zone, .bottom)
        XCTAssertEqual(resolve(3500, 995)?.zone, .bottom)
        XCTAssertEqual(resolve(3500, 995)?.screen, ultrawide)
    }

    // MARK: - Ultrawide applies per display

    func testTheLaptopKeepsHalvesWhileTheUltrawideGetsThirds() {
        // The bug this file exists for: the drag path asked "is *any* ultrawide attached?" rather
        // than "is *this* screen ultrawide?", so plugging in an ultrawide silently retuned the
        // laptop's zones too. The README promises this doesn't happen.
        let settings = SnapSettings(
            defaults: UserDefaults(suiteName: "SnapMultiDisplay-\(UUID().uuidString)")!
        )

        let laptopIsWide = SnapZoneLayout.usesUltrawideLayout(screen: laptop, settingEnabled: true)
        let ultraIsWide = SnapZoneLayout.usesUltrawideLayout(screen: ultrawide, settingEnabled: true)

        XCTAssertFalse(laptopIsWide, "a 16:10 laptop is not ultrawide, whatever else is plugged in")
        XCTAssertTrue(ultraIsWide)

        XCTAssertEqual(settings.action(for: .left, ultrawide: laptopIsWide), .leftHalf)
        XCTAssertEqual(settings.action(for: .left, ultrawide: ultraIsWide), .firstThird)
    }

    func testTheSettingStillGatesEverything() {
        XCTAssertFalse(SnapZoneLayout.usesUltrawideLayout(screen: ultrawide, settingEnabled: false))
    }

    func testResolvingAndTheUltrawideDecisionUseTheSameScreen() {
        // The second bug: the zone came from the screen under the pointer while the rect came from
        // the screen under the window. Dragging a wide window toward the ultrawide's edge, with
        // most of the window still on the laptop, put the footprint on one display and the window
        // on the other. They must be one decision.
        guard let resolved = resolve(1605, 500) else { return XCTFail("expected the ultrawide") }
        XCTAssertEqual(resolved.screen, ultrawide)
        XCTAssertTrue(
            SnapZoneLayout.usesUltrawideLayout(screen: resolved.screen, settingEnabled: true),
            "the ultrawide decision must follow the screen the pointer resolved to"
        )
    }

    func testAWindowMostlyOnTheLaptopStillSnapsToTheUltrawideWhenDroppedThere() {
        // Same case stated from the window's side: containment by area would answer "laptop",
        // which is exactly why the pointer's screen has to win for a drag.
        let straddling = CGRect(x: 1200, y: 200, width: 800, height: 400)   // 400pt laptop, 400 ultra
        let byArea = ScreenCoordinates.screen(containing: straddling, screens: screens)
        let byPointer = resolve(1605, 500)?.screen

        XCTAssertEqual(byPointer, ultrawide)
        XCTAssertNotEqual(byArea, byPointer,
                          "if these agreed, the test couldn't detect the bug it exists for")
    }
}
