import AppKit
import XCTest
@testable import Sarvkrit

/// The crosshair has to be visible on whatever the user's screen happens to show.
///
/// **Nothing asserted this before.** The guides were a single 40% black hairline, which is
/// invisible over a dark editor and cannot be fixed by changing the alpha — and no test in the
/// suite touched the crosshair's colour, width or contrast, so it shipped that way unnoticed.
/// A single tone always loses somewhere; grey loses on grey. These render over the two extremes
/// and require the line to be found in both.
@MainActor
final class CrosshairContrastTests: XCTestCase {

    private let display = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2,
        pixelSize: CGSize(width: 800, height: 600))

    private func frozen(white: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: white, green: white, blue: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        return try XCTUnwrap(context.makeImage())
    }

    /// Renders the overlay with *only* the crosshair on it, so nothing else can account for the
    /// pixels this counts.
    private func render(over white: CGFloat) throws -> NSBitmapImageRep {
        let view = SelectionView(display: display, frozenImage: try frozen(white: white),
                                 mode: .area)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.showsMagnifier = false
        view.showsDimensions = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.seedPointer(CGPoint(x: 200, y: 150))
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Pixels differing from the backdrop by more than a third of the range.
    private func contrasting(_ rep: NSBitmapImageRep, against backdrop: CGFloat) -> Int {
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if abs(colour.brightnessComponent - backdrop) > 0.33 { count += 1 }
            }
        }
        return count
    }

    func testTheCrosshairIsVisibleOnABlackScreen() throws {
        // The reported case: a dark editor behind the overlay, where the old dark hairline showed
        // up only where it happened to cross white text.
        let rep = try render(over: 0)
        XCTAssertGreaterThan(contrasting(rep, against: 0), 200,
                             "the crosshair cannot be seen against black")
    }

    func testTheCrosshairIsVisibleOnAWhiteScreen() throws {
        // And the other extreme, which a plain white line would fail — the reason the bright core
        // carries a dark edge rather than standing alone.
        let rep = try render(over: 1)
        XCTAssertGreaterThan(contrasting(rep, against: 1), 200,
                             "the crosshair cannot be seen against white")
    }

    func testItIsVisibleOnMidGreyToo() throws {
        // The case both a plain white line and a plain dark one can survive, and a grey one — the
        // colour originally asked for — cannot.
        let rep = try render(over: 0.5)
        XCTAssertGreaterThan(contrasting(rep, against: 0.5), 200,
                             "the crosshair cannot be seen against grey")
    }

    func testTurningItOffLeavesTheScreenAlone() throws {
        // The counterpart: if the setting is off, none of the above should be drawn at all.
        let view = SelectionView(display: display, frozenImage: try frozen(white: 0), mode: .area)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.showsCrosshair = false
        view.showsMagnifier = false
        view.showsDimensions = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.seedPointer(CGPoint(x: 200, y: 150))
        view.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertLessThan(contrasting(rep, against: 0), 50,
                          "something is still drawn with the crosshair switched off")
    }

    func testTheGuidePairIsALightCoreOnADarkerEdge() {
        // Stated as values, because the whole failure was one flat tone. If these ever collapse to
        // a single colour the rendering tests above would still pass on one background.
        // `whiteComponent`, not `brightnessComponent`: these are greyscale colours and the HSB
        // accessors throw on that colour space rather than converting.
        XCTAssertGreaterThan(CaptureChrome.Overlay.guideCore.whiteComponent, 0.9)
        XCTAssertLessThan(CaptureChrome.Overlay.guideEdge.whiteComponent, 0.1)
        XCTAssertGreaterThan(CaptureChrome.Overlay.guideEdgeWidth,
                             CaptureChrome.Overlay.guideWidth,
                             "the edge must be wider than the core or it never shows")
    }
}
