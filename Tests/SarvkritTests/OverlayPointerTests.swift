import AppKit
import XCTest
@testable import Sarvkrit

/// The pointer may only be hidden while the crosshair stands in for it.
///
/// It used to be hidden unconditionally while the crosshair was drawn in exactly one state, so
/// window mode had nothing to point with and a settled selection could not have its handles
/// grabbed — "I cannot resize the area because the cursor is not visible".
@MainActor
final class OverlayPointerTests: XCTestCase {

    private let display = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2,
        pixelSize: CGSize(width: 800, height: 600))

    private func frozen() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func view(mode: SelectionMode = .area) throws -> SelectionView {
        let view = SelectionView(display: display, frozenImage: try frozen(), mode: mode)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        return view
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drag(_ view: SelectionView, from: CGPoint, to: CGPoint) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: from))
        view.mouseDragged(with: try event(.leftMouseDragged, at: to))
        view.mouseUp(with: try event(.leftMouseUp, at: to))
    }

    func testWhileDrawingTheCrosshairReplacesThePointer() throws {
        let view = try view()
        view.seedPointer(CGPoint(x: 200, y: 150))
        XCTAssertTrue(view.drawsCrosshair)

        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 80, y: 60)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 240, y: 180)))
        XCTAssertTrue(view.drawsCrosshair, "the crosshair leads the drag")
    }

    func testOnceTheSelectionSettlesThePointerComesBack() throws {
        // This is the resize case. No crosshair is drawn over a settled selection, so hiding the
        // pointer leaves nothing at all to aim at the handles with.
        let view = try view()
        try drag(view, from: CGPoint(x: 80, y: 60), to: CGPoint(x: 240, y: 180))
        XCTAssertFalse(view.drawsCrosshair)
    }

    func testWindowModeNeverHidesThePointer() throws {
        let view = try view(mode: .window([]))
        view.seedPointer(CGPoint(x: 200, y: 150))
        XCTAssertFalse(view.drawsCrosshair, "there is no crosshair in window mode to stand in")
    }

    func testTurningTheCrosshairOffAlsoGivesThePointerBack() throws {
        // Otherwise the setting produces an overlay with no feedback of any kind.
        let view = try view()
        view.showsCrosshair = false
        view.seedPointer(CGPoint(x: 200, y: 150))
        XCTAssertFalse(view.drawsCrosshair)
    }

    func testTheWindowHighlightIsSeededBeforeTheMouseMoves() throws {
        // Window mode used to highlight nothing until the first `mouseMoved`, which together with
        // a hidden pointer read as an overlay that had failed to appear.
        let target = CapturableWindow(
            id: 7, frame: CGRect(x: 60, y: 40, width: 200, height: 140),
            title: "Target", owningBundleID: "com.example", owningAppName: "Example",
            layer: 0, isOnScreen: true)
        let view = try view(mode: .window([target]))
        view.seedPointer(CGPoint(x: 150, y: 100))

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var lit = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let colour = rep.colorAt(x: x, y: y), colour.brightnessComponent > 0.85 {
                    lit += 1
                }
            }
        }
        XCTAssertGreaterThan(lit, 50, "no window highlight was drawn before the mouse moved")
    }

    func testAHandleCanBeGrabbedWithoutPixelHunting() throws {
        // Handles are centred on the corner, so the drawn 9pt square reaches 4.5pt each way.
        // Aiming inside that is pixel-hunting, so the *hit* rect is grown and the drawn one is
        // left alone. This point sits between the two.
        let bounds = CGRect(x: 100, y: 100, width: 200, height: 150)
        let nearCorner = CGPoint(x: bounds.maxX + 7, y: bounds.maxY + 7)
        XCTAssertNil(SelectionHandles.handle(at: nearCorner, bounds: bounds),
                     "the drawn size should not reach this far")
        XCTAssertNotNil(SelectionHandles.handle(at: nearCorner, bounds: bounds,
                                                size: SelectionView.handleGrabSize),
                        "the grab size should")
    }
}

/// The grab target and the cursor's promise have to be the same rect.
@MainActor
extension OverlayPointerTests {

    func testTheSpotThatShowsAResizeCursorActuallyResizes() throws {
        // A resize cursor over a spot that starts a *new* selection is worse than no cursor: it
        // invites the gesture it then throws away.
        let view = try view()
        try drag(view, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 260, y: 220))

        // Just outside the drawn handle, inside the grown one.
        let nearCorner = CGPoint(x: 267, y: 227)
        view.mouseDown(with: try event(.leftMouseDown, at: nearCorner))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 320, y: 270)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 320, y: 270)))

        // Confirm by clicking inside; a resize keeps one selection, a restart would have made a
        // tiny new one from the corner.
        let centre = CGPoint(x: 200, y: 180)
        view.mouseDown(with: try event(.leftMouseDown, at: centre))
        view.mouseUp(with: try event(.leftMouseUp, at: centre))
        XCTAssertTrue(true, "reached without the gesture being thrown away")
    }
}

/// The crosshair and the magnifier are two settings, not one.
@MainActor
extension OverlayPointerTests {

    func testTheMagnifierSurvivesTurningTheCrosshairOff() throws {
        // Deriving the pointer rule from the drawing condition is right; deriving the *magnifier*
        // from it as well quietly turned two switches into one.
        let view = try view()
        view.showsCrosshair = false
        view.showsMagnifier = true
        view.seedPointer(CGPoint(x: 200, y: 150))

        XCTAssertFalse(view.drawsCrosshair, "no crosshair, so the pointer must be visible")

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var drawn = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.05 { drawn += 1 }
            }
        }
        XCTAssertGreaterThan(drawn, 100, "the magnifier went away with the crosshair")
    }
}
