import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The compositor, asserted differentially.
///
/// **Why this is a test and not a scratch harness.** Four real bugs in the screenshot toolbar were
/// invisible to every unit test and obvious in a picture, which is what `EditorChromeSnapshotTests`
/// exists to catch. The same is true here and more so: a cursor drawn a few pixels off, a zoom
/// applied to the wrong axis, or a caption clipped by its own box are all things assertions do not
/// see. So each layer is switched on and off and the frames are required to differ — the cheapest
/// possible guard against a layer silently doing nothing — and `make preview` writes the PNGs so a
/// person can look.
final class StudioRenderSnapshotTests: XCTestCase {

    private let canvas = CGSize(width: 800, height: 500)

    /// A recognisable screen: quarters in four colours, so a zoom or a flip is visible at a glance.
    private func screen() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colours = [CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1),
                       CGColor(red: 0.3, green: 0.7, blue: 0.4, alpha: 1),
                       CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1),
                       CGColor(red: 0.95, green: 0.8, blue: 0.3, alpha: 1)]
        for (index, colour) in colours.enumerated() {
            context.setFillColor(colour)
            context.fill(CGRect(x: index % 2 == 0 ? 0 : 400, y: index < 2 ? 0 : 250,
                                width: 400, height: 250))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func project() -> StudioProject {
        StudioProject(canvasSize: canvas,
                      timeline: Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 10)]))
    }

    private func events() -> EventLog {
        let cursor = (0..<200).map {
            CursorSample(t: Double($0) * 0.05,
                         point: CGPoint(x: 100 + Double($0) * 3, y: 250), kind: .arrow)
        }
        let clicks = [ClickEvent(t: 2, point: CGPoint(x: 400, y: 250),
                                 button: .left, isDown: true)]
        return EventLog(cursor: cursor, clicks: clicks)
    }

    private func render(_ project: StudioProject, at t: TimeInterval,
                        events log: EventLog? = nil) throws -> CGImage {
        try XCTUnwrap(StudioRenderer.frame(of: project, atSource: t,
                                           events: log ?? events(),
                                           sources: FrameSources(screen: try screen())))
    }

    private func png(_ image: CGImage) -> Data? { CaptureWriter.pngData(from: image) }

    private func write(_ image: CGImage, named name: String) throws {
        guard let directory = PreviewDirectory.path else { return }
        try XCTUnwrap(png(image))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // MARK: - It draws at all

    func testAFrameIsProduced() throws {
        let frame = try render(project(), at: 1)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        try write(frame, named: "studio-plain")
    }

    /// The canvas is bigger than the recording, because padding grows it. If these were equal the
    /// background would be invisible and the whole surround would be doing nothing.
    func testTheCanvasIsLargerThanTheRecording() throws {
        let frame = try render(project(), at: 1)
        XCTAssertGreaterThan(frame.width, Int(canvas.width))
    }

    // MARK: - Layers

    func testAZoomChangesTheFrame() throws {
        var zoomed = project()
        zoomed.zooms = [ZoomSegment(start: 0, end: 8, level: 2.4,
                                    anchor: .fixed(CGPoint(x: 0.3, y: 0.3)))]
        let plain = try render(project(), at: 3)
        let close = try render(zoomed, at: 3)
        XCTAssertNotEqual(png(plain), png(close), "the zoom did nothing")
        try write(close, named: "studio-zoomed")
    }

    func testHidingTheCursorChangesTheFrame() throws {
        var hidden = project()
        hidden.cursor.isHidden = true
        XCTAssertNotEqual(png(try render(project(), at: 3)), png(try render(hidden, at: 3)),
                          "the cursor was not being drawn")
    }

    func testTheClickEffectChangesTheFrame() throws {
        var none = project()
        none.cursor.clickEffect = .none
        // Just after the click, while the ripple is at its most visible.
        XCTAssertNotEqual(png(try render(project(), at: 2.05)),
                          png(try render(none, at: 2.05)),
                          "the click effect did nothing")
        try write(try render(project(), at: 2.05), named: "studio-click")
    }

    func testChangingTheBackgroundChangesTheFrame() throws {
        var other = project()
        other.background.fill = .builtIn(id: "ember")
        XCTAssertNotEqual(png(try render(project(), at: 1)), png(try render(other, at: 1)))
    }

    func testRemovingThePaddingChangesTheFrame() throws {
        var tight = project()
        tight.background.padding = 0
        XCTAssertNotEqual(png(try render(project(), at: 1)), png(try render(tight, at: 1)))
    }

    func testACaptionChangesTheFrame() throws {
        var captioned = project()
        captioned.captions = [Caption(words: [
            TranscriptWord(text: "you", start: 0.5, duration: 0.3),
            TranscriptWord(text: "press", start: 0.8, duration: 0.3),
            TranscriptWord(text: "command", start: 1.1, duration: 0.5),
        ])]
        let with = try render(captioned, at: 1.0)
        XCTAssertNotEqual(png(try render(project(), at: 1.0)), png(with), "no caption was drawn")
        try write(with, named: "studio-caption")
    }

    /// Karaoke highlighting: the same line at two moments must look different, because a different
    /// number of words has been spoken.
    func testACaptionHighlightsAsItIsSpoken() throws {
        var captioned = project()
        captioned.captions = [Caption(words: [
            TranscriptWord(text: "you", start: 0.5, duration: 0.3),
            TranscriptWord(text: "press", start: 1.5, duration: 0.3),
            TranscriptWord(text: "command", start: 2.5, duration: 0.5),
        ])]
        XCTAssertNotEqual(png(try render(captioned, at: 0.6)),
                          png(try render(captioned, at: 2.6)),
                          "the caption did not highlight word by word")
    }

    // MARK: - Consistency

    /// Preview and export call the same function, so the same project at the same time must give
    /// the same bytes. This is the test that keeps that promise honest.
    func testTheSameMomentRendersIdentically() throws {
        XCTAssertEqual(png(try render(project(), at: 4)), png(try render(project(), at: 4)))
    }

    /// Past the end of the recording there is no frame to show. The surround should still be drawn
    /// rather than the whole thing coming back black or nil.
    func testAMissingScreenFrameStillDrawsTheSurround() throws {
        let frame = try XCTUnwrap(StudioRenderer.frame(of: project(), atSource: 99,
                                                       events: events(),
                                                       sources: FrameSources(screen: nil)))
        XCTAssertGreaterThan(frame.width, 0)
    }
}
