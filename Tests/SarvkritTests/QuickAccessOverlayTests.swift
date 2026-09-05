import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// The two faults reported first: the overlay's buttons did nothing, and it stuck.
@MainActor
final class QuickAccessOverlayTests: XCTestCase {

    private func image() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 260, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 260))
        let cgImage = try XCTUnwrap(context.makeImage())
        return NSImage(cgImage: cgImage, size: NSSize(width: 400, height: 260))
    }

    /// The overlay's view, hosted and laid out, with the hover controls showing.
    private func hosted() throws -> NSView {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qao.png")
        let view = QuickAccessView(image: try image(), fileURL: url, dimensions: "400 × 260",
                                   onAnnotate: {}, onPin: {},
                                   onCopy: {}, onSave: {}, onReveal: {}, onClose: {},
                                   onSwipeAway: {}, onHoverChange: { _ in })
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testTheDragSourceIsStillThereAndSized() throws {
        // Moving it under the controls must not cost the drag: the thumbnail is how a capture
        // reaches another app without saving a file first. A representable that collapsed to zero
        // would leave the buttons working and nothing draggable.
        let host = try hosted()
        var found: NSView?
        func walk(_ view: NSView) {
            if view is CaptureDragSource.DragSourceView { found = view }
            view.subviews.forEach(walk)
        }
        walk(host)
        let drag = try XCTUnwrap(found, "no drag source in the overlay at all")
        XCTAssertGreaterThan(drag.frame.width, 100)
        XCTAssertGreaterThan(drag.frame.height, 80)
    }

    func testTheHoverControlsRenderOverTheThumbnail() throws {
        // The controls only exist on hover and SwiftUI hover cannot be synthesised, so this is
        // the one state worth checking and the one that could not be looked at. Rendering it and
        // comparing against the resting state is what shows the buttons are actually drawn.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qao.png")
        func render(hovered: Bool) throws -> NSBitmapImageRep {
            let view = QuickAccessView(image: try image(), fileURL: url, dimensions: "400 × 260",
                                       onAnnotate: {}, onPin: {},
                                       onCopy: {}, onSave: {}, onReveal: {}, onClose: {},
                                       onSwipeAway: {}, startsHovered: hovered,
                                       onHoverChange: { _ in })
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
            // In a window, because the view fades itself in from `.onAppear` — which never fires
            // outside one, so an unhosted render is a blank rectangle at zero opacity.
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        let resting = try render(hovered: false)
        let hovered = try render(hovered: true)
        XCTAssertNotEqual(resting.representation(using: .png, properties: [:]),
                          hovered.representation(using: .png, properties: [:]),
                          "hovering drew nothing — the controls are not being rendered")

        if let directory = PreviewDirectory.path {
            try XCTUnwrap(hovered.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("qao-hover.png"))
        }
    }

    func testAStaleHoverIsClearedByTheTickRatherThanPausingForever() throws {
        // Hovering pauses the auto-close countdown, and the only source of "the pointer left" was
        // a SwiftUI event that an AppKit view on top could swallow. One missed exit paused it for
        // good, which — with Discard unclickable — is why the overlay stuck.
        let now = Date()
        let shown = now.addingTimeInterval(-60)
        XCTAssertTrue(QuickAccessTimer.hasExpired(now: now, shownAt: shown,
                                                  duration: 4, hoveredSince: nil),
                      "an unhovered overlay past its time must expire")

        // The trap: the hover began *before* the countdown ran out, so the clock is stopped at
        // two seconds in and stays there for ever. Sixty seconds later it has still not expired,
        // which is precisely why the tick must re-derive hover from where the pointer really is
        // rather than trust an exit event that can go missing.
        XCTAssertFalse(QuickAccessTimer.hasExpired(now: now, shownAt: shown, duration: 4,
                                                   hoveredSince: shown.addingTimeInterval(2)),
                       "the pause is what strands the overlay, and it is still paused")
    }

}
