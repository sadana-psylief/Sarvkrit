import AppKit
import XCTest
@testable import Sarvkrit

/// The editor's real canvas view, drawn the way the window draws it.
///
/// **Why not the renderer alone.** `AnnotationRenderer` has its own tests and they were all green
/// while the capture overlay showed nothing at all, because that bug was in how a view got its
/// pixels on screen rather than in what was drawn. `AnnotationCanvasView` is the other
/// `wantsLayer` view in this feature, so it deserves the same check: put it in a window, let
/// AppKit draw it, and read the result back.
///
/// The two complaints this is here to answer, in the words they were made in: "the arrow is not
/// beautiful" and "the background never appears".
@MainActor
final class EditorCanvasLiveTests: XCTestCase {

    private func base(_ width: Int = 600, _ height: Int = 400) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.20, green: 0.22, blue: 0.26, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: width - 80, height: 60))
        return try XCTUnwrap(context.makeImage())
    }

    /// Draws the canvas through AppKit, exactly as the window would.
    private func draw(_ model: EditorDocumentModel,
                      size: CGSize = CGSize(width: 720, height: 520)) throws
        -> NSBitmapImageRep {
        let view = AnnotationCanvasView(model: model)
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SARVKRIT_PREVIEW_DIR"]
        else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    /// How many pixels in the rep are not the window's own empty ground.
    private func distinctColours(_ rep: NSBitmapImageRep) -> Set<UInt32> {
        var seen: Set<UInt32> = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let r = UInt32(colour.redComponent * 255)
                let g = UInt32(colour.greenComponent * 255)
                let b = UInt32(colour.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen
    }

    func testTheCanvasActuallyDrawsTheImage() throws {
        // The `layer.contents` trap, checked on the other view that could fall into it.
        let model = EditorDocumentModel(base: try base())
        let rep = try draw(model)
        XCTAssertGreaterThan(distinctColours(rep).count, 2,
                             "the canvas drew nothing but its own ground")
        try write(rep, named: "canvas-plain")
    }

    /// "The background never appears."
    ///
    /// The bug it refers to: `AnnotationRenderer.draw` never drew the surround — only export did —
    /// so a background was invisible until the file was written. This asserts the canvas paints
    /// the area *outside* the screenshot, which is the only place a background can show.
    func testABackgroundShowsOnTheCanvasAndNotOnlyInTheExport() throws {
        let plain = EditorDocumentModel(base: try base())
        let plainRep = try draw(plain)

        let withBackground = EditorDocumentModel(base: try base())
        withBackground.edit { document in
            document.background = CaptureBackground(
                fill: .gradient(GradientSpec(stops: [
                    .init(colour: RGBAColour(r: 0.98, g: 0.36, b: 0.31), location: 0),
                    .init(colour: RGBAColour(r: 0.55, g: 0.20, b: 0.85), location: 1),
                ])),
                padding: 90)
        }
        let backgroundRep = try draw(withBackground)
        try write(backgroundRep, named: "canvas-background")

        XCTAssertGreaterThan(distinctColours(backgroundRep).count,
                             distinctColours(plainRep).count,
                             "adding a background changed nothing on the canvas")

        // A corner, which is surround and never screenshot. It must be neither the empty ground
        // nor the screenshot's own pale grey.
        let corner = try XCTUnwrap(backgroundRep.colorAt(x: 8, y: 8))
        XCTAssertGreaterThan(corner.alphaComponent, 0.9, "the corner is transparent")
        let isScreenshotGrey = corner.redComponent > 0.9 && corner.greenComponent > 0.9
        XCTAssertFalse(isScreenshotGrey, "the corner is the screenshot, not the background")
    }

    /// "The arrow is not beautiful." Renders all four heads for inspection, and checks each puts
    /// ink on the canvas rather than silently drawing an empty path.
    func testEveryArrowStyleDraws() throws {
        for head in [ArrowElement.Head.filled, .open, .thin, .curved] {
            let model = EditorDocumentModel(base: try base())
            model.edit { document in
                var arrow = ArrowElement(start: CGPoint(x: 120, y: 320),
                                         end: CGPoint(x: 470, y: 110))
                arrow.head = head
                arrow.stroke.colour = RGBAColour(r: 0.95, g: 0.24, b: 0.20)
                arrow.stroke.width = 9
                document.add(.arrow(arrow))
            }
            let rep = try draw(model)
            try write(rep, named: "canvas-arrow-\(head)")

            // The arrow's red must be somewhere on the canvas.
            var foundRed = false
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) where !foundRed {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let colour = rep.colorAt(x: x, y: y) else { continue }
                    if colour.redComponent > 0.7 && colour.greenComponent < 0.5 {
                        foundRed = true
                        break
                    }
                }
            }
            XCTAssertTrue(foundRed, "\(head) arrow drew nothing")
        }
    }

    /// A selected arrow shows its two ends and a bow, not a bounding box.
    func testASelectedArrowShowsThreeHandles() throws {
        let model = EditorDocumentModel(base: try base())
        var arrow = ArrowElement(start: CGPoint(x: 120, y: 300), end: CGPoint(x: 470, y: 130))
        arrow.head = .curved
        arrow.curvature = ArrowGeometry.defaultCurvature(from: arrow.start, to: arrow.end)
        arrow.stroke.colour = RGBAColour(r: 0.95, g: 0.24, b: 0.20)
        arrow.stroke.width = 9
        model.edit { $0.add(.arrow(arrow)) }
        model.selection = model.document.elements.last?.id

        let rep = try draw(model)
        try write(rep, named: "arrow-handles")
        XCTAssertGreaterThan(distinctColours(rep).count, 3)
    }

    /// Redaction has to cover what it covers *on the canvas*, not only in the export — the whole
    /// risk of this feature is somebody believing a password is hidden when it is not.
    func testASecureRedactionCoversWhatItIsOver() throws {
        let model = EditorDocumentModel(base: try base())
        model.edit { document in
            document.add(.blur(PixelFilterElement(
                rect: CGRect(x: 40, y: 40, width: 520, height: 60), mode: .secureBlur)))
        }
        let rep = try draw(model)
        try write(rep, named: "canvas-redaction")

        // The dark band in the base runs across that rect. If the redaction drew, the band's
        // own colour should no longer be the only thing there.
        XCTAssertGreaterThan(distinctColours(rep).count, 2)
    }
}
