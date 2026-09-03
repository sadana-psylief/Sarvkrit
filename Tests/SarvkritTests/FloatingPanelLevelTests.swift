import AppKit
import XCTest
@testable import Sarvkrit

/// That a panel ends up at the level it asked for.
///
/// This exists because it did not. `isFloatingPanel = true` assigns `.floating` as a side effect,
/// so a panel configured with the shielding level and *then* marked floating comes out at level 3
/// — above ordinary windows, below the menu bar. Nothing looked wrong: the capture overlay shows a
/// photograph of the screen it is covering, so an overlay at the wrong level and an overlay at the
/// right one are the same picture. It took reading `kCGWindowLayer` off the live window.
@MainActor
final class FloatingPanelLevelTests: XCTestCase {

    func testAPanelKeepsTheLevelItWasGiven() {
        let shielding = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  style: .init(level: shielding))
        XCTAssertEqual(panel.level, shielding)
        XCTAssertNotEqual(panel.level, .floating, "isFloatingPanel overwrote it again")
    }

    func testTheCaptureOverlayOutranksTheMenuBar() {
        // The whole reason the overlay asks for the shielding level: a menu bar left live above a
        // frozen screen is a menu bar the user can open and that the capture will not contain.
        let shielding = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        XCTAssertGreaterThan(shielding.rawValue, NSWindow.Level.mainMenu.rawValue)

        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  style: .init(level: shielding, acceptsKey: true))
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    func testTheDefaultIsStillFloating() {
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  style: .init())
        XCTAssertEqual(panel.level, .floating)
    }

    func testAPanelThatNeedsEscapeCanTakeTheKeyboard() {
        // `canBecomeKey` is overridden from the style; an overlay that cannot become key never
        // receives Escape, and then there is no way out of it.
        let keyable = FloatingPanel(contentRect: .zero, style: .init(acceptsKey: true))
        XCTAssertTrue(keyable.canBecomeKey)
        XCTAssertFalse(keyable.canBecomeMain, "never main — Sarvkrit is not a document app")

        let decorative = FloatingPanel(contentRect: .zero, style: .init(acceptsKey: false))
        XCTAssertFalse(decorative.canBecomeKey)
    }
}
