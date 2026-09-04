import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// The pinned shot, which produced three complaints from one bug.
@MainActor
final class PinnedShotRenderTests: XCTestCase {

    private func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 200, height: 140))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 140).fill()
        image.unlockFocus()
        return image
    }

    private func hosted(_ pin: PinnedShotController.Pin) -> NSHostingView<PinnedShotView> {
        let view = PinnedShotView(pin: pin, image: image(),
                                  onOpacityChange: { pin.opacity = $0 },
                                  onLockChange: { pin.isLocked = $0 },
                                  onClose: {}, onCopy: {}, onResize: { _ in })
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 140)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func pixels(_ host: NSView) throws -> Data {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Waits for SwiftUI to actually re-run `body`.
    ///
    /// `NSHostingView` updates from a main-run-loop observer, not synchronously when a `@Published`
    /// value changes, so `layoutSubtreeIfNeeded()` alone does not flush it. Locally something else
    /// pumped the loop and the redraw landed before the next render; on CI nothing did, and two
    /// byte-identical PNGs read as "the change never reached the screen". Polling until it changes
    /// — rather than sleeping a fixed amount — keeps the pass fast and the failure honest.
    private func redraws(_ host: NSView, from before: Data,
                         timeout: TimeInterval = 5) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            host.layoutSubtreeIfNeeded()
            if try pixels(host) != before { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return false
    }

    private func makePin() -> PinnedShotController.Pin {
        PinnedShotController.Pin(panel: FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 140), style: .init()))
    }

    /// The bug, stated as a test.
    func testChangingOpacityRedrawsWithoutNeedingAHover() throws {
        // `Pin` was a plain class read through `Binding(get:set:)`, so writing it changed the model
        // and nothing else — SwiftUI had no reason to re-run `body`. The slider did nothing until
        // the pointer left the window and flipped `isHovering`, which is exactly the "wasn't
        // working, then somehow worked" that was reported.
        let pin = makePin()
        let host = hosted(pin)
        let before = try pixels(host)

        pin.opacity = 0.3
        XCTAssertTrue(try redraws(host, from: before),
                      "the opacity change never reached the screen")
    }

    func testLockingRedrawsSoTheIconAndBorderSayItIsLocked() throws {
        // The lock chip kept showing `lock.open` after locking, so the icon could not tell you
        // which state you were in — while `ignoresMouseEvents` had already made every control on
        // the window dead.
        let pin = makePin()
        let host = hosted(pin)
        let before = try pixels(host)

        pin.isLocked = true
        XCTAssertTrue(try redraws(host, from: before),
                      "locking left the window looking unlocked")
    }

    func testOpacityIsClampedSoAPinCannotBecomeAnInvisibleClickTrap() {
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(0), PinnedShotGeometry.minimumOpacity)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(-5), PinnedShotGeometry.minimumOpacity)
        XCTAssertEqual(PinnedShotGeometry.clampedOpacity(2), 1)
    }
}

/// Resizing, which was the second way a pin got stranded.
final class PinnedShotResizeTests: XCTestCase {

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 950)

    func testADragDoesNotCompoundIntoARunawayWindow() {
        // `DragGesture` reports translation from the start of the gesture; the handler applies
        // what it is given to the *current* frame. Passing the total each time made a 100pt drag
        // grow the window by roughly a thousand. The view now sends the increment, so replaying
        // one gesture must land on one gesture's worth of growth.
        var frame = CGRect(x: 100, y: 400, width: 300, height: 200)
        var last = CGSize.zero
        for step in stride(from: 5.0, through: 100.0, by: 5.0) {
            let cumulative = CGSize(width: step, height: -step)
            let delta = CGSize(width: cumulative.width - last.width,
                               height: -(cumulative.height - last.height))
            last = cumulative
            frame = PinnedShotGeometry.resized(frame, by: delta, preservingAspect: true,
                                               displays: [display])
        }
        XCTAssertEqual(frame.width, 400, accuracy: 1, "a 100pt drag should add 100pt")
    }

    func testAPinCannotBeGrownPastTheDisplayItIsOn() {
        // An always-on-top window wider than the screen has its close button off the edge.
        var frame = CGRect(x: 1200, y: 700, width: 200, height: 150)
        for _ in 0..<50 {
            frame = PinnedShotGeometry.resized(frame, by: CGSize(width: 200, height: 200),
                                               preservingAspect: true, displays: [display])
        }
        XCTAssertLessThanOrEqual(frame.maxX, display.maxX + 0.5, "grew off the right edge")
        XCTAssertGreaterThanOrEqual(frame.minY, display.minY - 0.5, "grew off the bottom")
    }

    func testItStillCannotBeShrunkBelowItsControls() {
        var frame = CGRect(x: 100, y: 400, width: 300, height: 200)
        for _ in 0..<50 {
            frame = PinnedShotGeometry.resized(frame, by: CGSize(width: -100, height: -100),
                                               preservingAspect: true, displays: [display])
        }
        XCTAssertGreaterThanOrEqual(frame.width, PinnedShotGeometry.minimumSide)
        XCTAssertGreaterThanOrEqual(frame.height, PinnedShotGeometry.minimumSide)
    }

    func testTheTopLeftCornerStaysPut() {
        let frame = CGRect(x: 100, y: 400, width: 300, height: 200)
        let resized = PinnedShotGeometry.resized(frame, by: CGSize(width: 60, height: 40),
                                                 preservingAspect: false, displays: [display])
        XCTAssertEqual(resized.minX, frame.minX)
        XCTAssertEqual(resized.maxY, frame.maxY, "the corner not being dragged moved")
    }

    func testWithNoDisplaysItStillRefusesToVanish() {
        let frame = PinnedShotGeometry.resized(CGRect(x: 0, y: 0, width: 100, height: 100),
                                               by: CGSize(width: -500, height: -500),
                                               preservingAspect: true, displays: [])
        XCTAssertGreaterThanOrEqual(frame.width, PinnedShotGeometry.minimumSide)
    }
}
