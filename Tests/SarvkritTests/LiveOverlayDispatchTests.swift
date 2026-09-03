import AppKit
import XCTest
@testable import Sarvkrit

/// The real overlay panel, on screen, driven through AppKit's own event dispatch.
///
/// **What this reaches that the other overlay tests do not.** `SelectionOverlayInteractionTests`
/// calls `mouseDown(with:)` on the view directly, which proves the handlers are right but says
/// nothing about whether an event would ever arrive at them. This builds the panel the app builds
/// — shielding level, non-activating, `canBecomeKey` overridden — orders it on screen, and hands
/// events to `NSApp.sendEvent(_:)`, which is precisely the call `NSApplication` makes on every
/// event it takes off its queue. Everything from there down is the real chain: application →
/// window → first responder → view.
///
/// The one link still outside this is the window server handing the event to the process, which
/// needs an Accessibility grant to synthesise. That link is also the one macOS is responsible for.
///
/// **Safety.** A full-screen panel at shielding level is exactly what got left on screen once
/// before, so every test here dismisses in a teardown block that runs even when the test fails,
/// and the escape hatch is called as well as the controller's own `dismiss`.
@MainActor
final class LiveOverlayDispatchTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        addTeardownBlock { @MainActor in
            CaptureOverlayController.shared.dismiss()
            CaptureOverlayGuard.shared.dismissEverything()
        }
    }

    private func frame(for screen: NSScreen) throws -> DisplayFrame {
        let scale = screen.backingScaleFactor
        let pixels = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixels))
        let geometry = DisplaySnapshotGeometry(
            displayID: screen.displayID ?? CGMainDisplayID(),
            frame: screen.frame, scale: scale, pixelSize: pixels)
        return DisplayFrame(geometry: geometry, image: try XCTUnwrap(context.makeImage()))
    }

    /// An event addressed to the panel, the way the window server addresses one.
    private func mouse(_ type: NSEvent.EventType, at local: CGPoint,
                       in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            // `locationInWindow`, which is what a real event carries.
            location: local,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func present(mode: SelectionMode = .area) throws
        -> (panel: NSWindow, result: Box) {
        let screen = try XCTUnwrap(NSScreen.main)
        let box = Box()
        CaptureOverlayController.shared.present(frames: [try frame(for: screen)],
                                                mode: mode) { image, display, rect in
            box.image = image
            box.display = display
            box.rect = rect
            box.completed = true
        }
        let panel = try XCTUnwrap(NSApp.windows.first { $0 is FloatingPanel && $0.isVisible })
        return (panel, box)
    }

    final class Box {
        var image: CGImage?
        var display: DisplaySnapshotGeometry?
        var rect: CGRect?
        var completed = false
    }

    func testTheRealPanelIsOnScreenAtTheShieldingLevelAndTakesTheKeyboard() throws {
        let (panel, _) = try present()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level.rawValue, Int(CGShieldingWindowLevel()))
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
        XCTAssertTrue(panel.canBecomeKey, "no Escape without this")
        XCTAssertTrue(panel.acceptsMouseMovedEvents, "no crosshair without this")
        XCTAssertTrue(panel.contentView is SelectionView)
        XCTAssertTrue(panel.firstResponder is SelectionView,
                      "keys would go to the window, not the view")
    }

    /// Mouse tracking, through the same dispatch as the clicks.
    ///
    /// `acceptsMouseMovedEvents` is asserted above; this is the other half — that a moved event
    /// arriving at the application actually lands on the view and moves the crosshair. Together
    /// they cover everything about tracking except the window server's own delivery.
    func testMouseMovedThroughAppKitsDispatchMovesTheCrosshair() throws {
        let (panel, _) = try present()
        let view = try XCTUnwrap(panel.contentView as? SelectionView)
        let height = panel.frame.height

        NSApp.sendEvent(try mouse(.mouseMoved, at: CGPoint(x: 300, y: height - 300), in: panel))
        let first = try XCTUnwrap(view.pointer, "the view never learned where the pointer was")

        NSApp.sendEvent(try mouse(.mouseMoved, at: CGPoint(x: 700, y: height - 500), in: panel))
        let second = try XCTUnwrap(view.pointer)

        XCTAssertNotEqual(first, second, "the crosshair stayed where it was")
        XCTAssertEqual(second.x - first.x, 400, accuracy: 1)
        XCTAssertEqual(abs(second.y - first.y), 200, accuracy: 1)
    }

    /// A drag and the click that takes it, delivered by `NSApp.sendEvent`.
    func testADragThroughAppKitsDispatchProducesACroppedImage() throws {
        let (panel, box) = try present()
        let height = panel.frame.height

        // Bottom-left origin, in the panel's coordinates, which is what an event carries.
        NSApp.sendEvent(try mouse(.leftMouseDown, at: CGPoint(x: 200, y: height - 200), in: panel))
        NSApp.sendEvent(try mouse(.leftMouseDragged, at: CGPoint(x: 500, y: height - 400), in: panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: CGPoint(x: 500, y: height - 400), in: panel))
        XCTAssertFalse(box.completed, "mouse-up settles the selection; it does not take the shot")

        // The click inside that takes it — the gesture that was silently cancelling until it was
        // fixed, now driven all the way from `NSApplication`.
        NSApp.sendEvent(try mouse(.leftMouseDown, at: CGPoint(x: 350, y: height - 300), in: panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: CGPoint(x: 350, y: height - 300), in: panel))

        XCTAssertTrue(box.completed, "the click inside never reached the view")
        let image = try XCTUnwrap(box.image, "a confirmed selection must produce an image")
        let scale = try XCTUnwrap(box.display).scale
        XCTAssertEqual(CGFloat(image.width), 300 * scale, accuracy: 2)
        XCTAssertEqual(CGFloat(image.height), 200 * scale, accuracy: 2)
    }

    /// Escape, through the window's own dispatch.
    ///
    /// **Not `NSApp.sendEvent` here, and the difference is the point.** `NSApplication` routes a
    /// mouse event to the window its `windowNumber` names, but a key event to whichever window is
    /// *key* — so in a test host that is not the active application, a synthesised key event goes
    /// nowhere near this panel however it is addressed. That is an artefact of the harness, not of
    /// the app: the running app logs `key window: true` for this panel even when another
    /// application is frontmost. So the link worth testing here is the one below that:
    /// `NSWindow.sendEvent` → first responder → view, which is what `NSApplication` performs once
    /// it has chosen the window.
    func testEscapeThroughTheWindowsDispatchCancels() throws {
        let (panel, box) = try present()
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        panel.sendEvent(escape)

        XCTAssertTrue(box.completed, "Escape never reached the view")
        XCTAssertNil(box.image, "Escape cancels; it does not capture")
    }

    /// Return takes the settled selection, for a capture aimed entirely by keyboard.
    func testReturnThroughTheWindowsDispatchTakesTheSelection() throws {
        let (panel, box) = try present()
        let height = panel.frame.height
        NSApp.sendEvent(try mouse(.leftMouseDown, at: CGPoint(x: 100, y: height - 100), in: panel))
        NSApp.sendEvent(try mouse(.leftMouseDragged, at: CGPoint(x: 340, y: height - 260), in: panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: CGPoint(x: 340, y: height - 260), in: panel))

        let sendKey = { (keyCode: UInt16, characters: String) in
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)
            if let event { panel.sendEvent(event) }
        }
        // Arrow keys nudge the settled rect, which is the other half of aiming without a mouse.
        sendKey(124, "\u{f703}")   // right
        sendKey(125, "\u{f701}")   // down
        sendKey(36, "\r")          // return

        XCTAssertTrue(box.completed)
        let image = try XCTUnwrap(box.image, "Return did not take the settled selection")
        let scale = try XCTUnwrap(box.display).scale
        XCTAssertEqual(CGFloat(image.width), 240 * scale, accuracy: 2, "nudging must not resize")
        XCTAssertEqual(CGFloat(image.height), 160 * scale, accuracy: 2)
        let rect = try XCTUnwrap(box.rect)
        XCTAssertEqual(rect.minX, 101, accuracy: 1, "one point right")
    }

    func testAClickWithNoDragDismissesRatherThanLeavingTheOverlayUp() throws {
        let (panel, box) = try present()
        let point = CGPoint(x: 400, y: panel.frame.height - 400)
        NSApp.sendEvent(try mouse(.leftMouseDown, at: point, in: panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: point, in: panel))
        XCTAssertTrue(box.completed)
        XCTAssertNil(box.image)
    }

    func testTheOverlayIsGoneAfterTheCaptureRatherThanLingering() throws {
        let (panel, _) = try present()
        let point = CGPoint(x: 400, y: panel.frame.height - 400)
        NSApp.sendEvent(try mouse(.leftMouseDown, at: point, in: panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: point, in: panel))
        XCTAssertTrue(NSApp.windows.filter { $0 is FloatingPanel && $0.isVisible }.isEmpty,
                      "a full-screen overlay left on screen is the worst bug this feature has had")
    }

    func testHoveringThenClickingAWindowPicksIt() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let target = CapturableWindow(
            id: 42,
            frame: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100,
                          width: 300, height: 200),
            title: "Target", owningBundleID: "com.example", owningAppName: "Example",
            layer: 0, isOnScreen: true)
        let (panel, box) = try present(mode: .window([target]))

        // Inside the target, in panel coordinates.
        let local = CGPoint(x: 250, y: 200)
        NSApp.sendEvent(try mouse(.mouseMoved, at: local, in: panel))
        NSApp.sendEvent(try mouse(.leftMouseDown, at: local, in: panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, at: local, in: panel))

        // Window mode hands the pick back to the session, which re-captures; the overlay's own job
        // is done the moment it reports one, so the panel must be gone.
        XCTAssertTrue(NSApp.windows.filter { $0 is FloatingPanel && $0.isVisible }.isEmpty)
        _ = box
    }
}
