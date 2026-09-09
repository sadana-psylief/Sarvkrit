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

    // MARK: - The later layers

    /// A mask must actually obscure. This is the layer where "it drew something" is not enough:
    /// the region has to stop showing what was underneath it.
    func testAMaskObscuresWhatIsUnderIt() throws {
        var masked = project()
        masked.masks = [StudioMask(mode: .secureBlur,
                                   rects: [CGRect(x: 100, y: 100, width: 300, height: 150)],
                                   start: 0, end: 10)]
        let hidden = try render(masked, at: 3)
        XCTAssertNotEqual(png(try render(project(), at: 3)), png(hidden), "the mask drew nothing")
        try write(hidden, named: "studio-mask")
    }

    /// The same four colours in the opposite corners: the mean is identical, the picture is not.
    private func scrambledScreen() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colours = [CGColor(red: 0.95, green: 0.8, blue: 0.3, alpha: 1),
                       CGColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1),
                       CGColor(red: 0.3, green: 0.7, blue: 0.4, alpha: 1),
                       CGColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1)]
        for (index, colour) in colours.enumerated() {
            context.setFillColor(colour)
            context.fill(CGRect(x: index % 2 == 0 ? 0 : 400, y: index < 2 ? 0 : 250,
                                width: 400, height: 250))
        }
        return try XCTUnwrap(context.makeImage())
    }

    /// The inverse mode: everything outside is dimmed, so the frame changes outside the region
    /// rather than inside it.
    func testAHighlightDimsEverythingElse() throws {
        var lit = project()
        lit.masks = [StudioMask(mode: .highlight,
                                rects: [CGRect(x: 300, y: 200, width: 200, height: 100)],
                                start: 0, end: 10)]
        let frame = try render(lit, at: 3)
        XCTAssertNotEqual(png(try render(project(), at: 3)), png(frame))
        try write(frame, named: "studio-highlight")
    }

    func testKeystrokePillsAreDrawn() throws {
        var typed = project()
        typed.keystrokes.isEnabled = true
        let log = EventLog(cursor: events().cursor,
                           keys: [KeyEvent(t: 2.9, label: "⌘⇧R", isModifierCombination: true)])
        let frame = try render(typed, at: 3, events: log)
        XCTAssertNotEqual(png(try render(project(), at: 3, events: log)), png(frame),
                          "no keystroke pill was drawn")
        try write(frame, named: "studio-keystrokes")
    }

    func testTheCameraIsDrawn() throws {
        let camera = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        camera.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.75, alpha: 1))
        camera.fill(CGRect(x: 0, y: 0, width: 400, height: 400))

        let frame = try XCTUnwrap(StudioRenderer.frame(
            of: project(), atSource: 3, events: events(),
            sources: FrameSources(screen: try screen(),
                                  camera: try XCTUnwrap(camera.makeImage()))))
        XCTAssertNotEqual(png(try render(project(), at: 3)), png(frame), "no camera was drawn")
        try write(frame, named: "studio-camera")
    }

    /// A camera hidden for a stretch must genuinely disappear, not merely fade.
    func testAHiddenCameraSegmentDrawsNoCamera() throws {
        var hidden = project()
        hidden.cameraSegments = [CameraSegment(start: 0, end: 10, layout: .hidden)]
        let camera = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        camera.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.75, alpha: 1))
        camera.fill(CGRect(x: 0, y: 0, width: 400, height: 400))

        let frame = try XCTUnwrap(StudioRenderer.frame(
            of: hidden, atSource: 3, events: events(),
            sources: FrameSources(screen: try screen(),
                                  camera: try XCTUnwrap(camera.makeImage()))))
        XCTAssertEqual(png(try render(hidden, at: 3)), png(frame))
    }

    /// **The security property, measured where it lives.**
    ///
    /// `secureBlur` deliberately keeps the region's mean colour — that is what makes a redaction
    /// sit in its surroundings rather than look like a sticker pasted on. What must never survive
    /// is *structure*. So the second screen holds exactly the same pixels rearranged: identical
    /// mean by construction, completely different picture.
    ///
    /// Asserted on the mean itself rather than on a whole rendered frame, deliberately. A frame
    /// comparison also captures the shadow, the corners and the cursor, so a failure would name
    /// the frame rather than the redaction — and a security property is the last thing to test
    /// through a confound.
    func testASecureBlurCarriesNoStructureFromThePixelsUnderIt() throws {
        let region = CGRect(x: 0, y: 0, width: 800, height: 500)
        let one = try XCTUnwrap(StudioRenderer.averageColour(of: try screen(), in: region))
        let other = try XCTUnwrap(StudioRenderer.averageColour(of: try scrambledScreen(),
                                                               in: region))
        XCTAssertEqual(one.r, other.r, accuracy: 0.002, "red leaked structure")
        XCTAssertEqual(one.g, other.g, accuracy: 0.002, "green leaked structure")
        XCTAssertEqual(one.b, other.b, accuracy: 0.002, "blue leaked structure")
    }

    // MARK: - Editing by hand

    /// **The seam, not the layer.** The camera test above hands `drawCamera` an image directly and
    /// therefore proved nothing about whether anything supplied one — which is exactly how the
    /// webcam went missing from every recording. These two go the other way: they change only the
    /// *project* and require the finished frame to differ, so the wiring is what is under test.
    func testAPointerHighlightDimsTheSurroundings() throws {
        var spotlit = project()
        spotlit.pointerHighlights = [PointerHighlight(start: 0, end: 10)]

        let plain = try render(project(), at: 3)
        let dimmed = try render(spotlit, at: 3)

        XCTAssertNotEqual(png(plain), png(dimmed), "no spotlight was drawn")
        try write(dimmed, named: "studio-pointer-highlight")
    }

    /// And it must genuinely end, rather than dimming the rest of the video.
    func testAPointerHighlightLeavesLaterFramesAlone() throws {
        var spotlit = project()
        spotlit.pointerHighlights = [PointerHighlight(start: 0, end: 2)]

        XCTAssertEqual(png(try render(project(), at: 6)), png(try render(spotlit, at: 6)))
    }

    /// A click placed by hand draws the same effect a recorded one does.
    func testAHandPlacedClickIsDrawn() throws {
        var edited = project()
        edited.clickEdits.added = [ManualClick(t: 6, point: CGPoint(x: 400, y: 250))]

        let plain = try render(project(), at: 6.05)
        let clicked = try render(edited, at: 6.05)

        XCTAssertNotEqual(png(plain), png(clicked), "the hand-placed click was not drawn")
    }

    /// And suppressing a recorded one takes it out of the picture. `events()` records a click at 2.
    func testASuppressedClickIsNotDrawn() throws {
        var edited = project()
        edited.clickEdits.suppressed = [2]

        let withClick = try render(project(), at: 2.05)
        let without = try render(edited, at: 2.05)

        XCTAssertNotEqual(png(withClick), png(without),
                          "the suppressed click is still in the picture")
    }

    /// Hand-placed text reaches the finished frame — the seam, not the layer.
    func testATextOverlayIsDrawn() throws {
        var titled = project()
        titled.textOverlays = [TextOverlay(start: 0, end: 10, text: "Look at this")]

        let plain = try render(project(), at: 3)
        let withText = try render(titled, at: 3)

        XCTAssertNotEqual(png(plain), png(withText), "the text was not drawn")
        try write(withText, named: "studio-text-overlay")
    }

    /// And it is gone once its range ends, rather than staying for the rest of the video.
    func testATextOverlayLeavesLaterFramesAlone() throws {
        var titled = project()
        titled.textOverlays = [TextOverlay(start: 0, end: 2, text: "Intro")]

        XCTAssertEqual(png(try render(project(), at: 6)), png(try render(titled, at: 6)))
    }

    /// Empty text draws nothing at all, so a freshly added line does not put a bare box on screen
    /// before anything has been typed into it.
    func testEmptyTextDrawsNothing() throws {
        var titled = project()
        titled.textOverlays = [TextOverlay(start: 0, end: 10, text: "")]

        XCTAssertEqual(png(try render(project(), at: 3)), png(try render(titled, at: 3)))
    }

    // MARK: - Fades

    /// **The wash reaches the frame, and only where it should.** A fade that darkened the middle
    /// of the video, or one that never reached the picture at all, would both pass a test that
    /// only checked the arithmetic.
    func testAFadeDarkensTheFirstFrameAndNotTheMiddle() throws {
        var faded = project()
        faded.fadeIn = 1

        let opening = try XCTUnwrap(StudioRenderer.frame(
            of: faded, atSource: 0, events: events(),
            sources: FrameSources(screen: try screen()), outputTime: 0))
        let plainOpening = try XCTUnwrap(StudioRenderer.frame(
            of: project(), atSource: 0, events: events(),
            sources: FrameSources(screen: try screen()), outputTime: 0))
        XCTAssertNotEqual(png(opening), png(plainOpening), "the fade never reached the picture")

        let middle = try XCTUnwrap(StudioRenderer.frame(
            of: faded, atSource: 5, events: events(),
            sources: FrameSources(screen: try screen()), outputTime: 5))
        let plainMiddle = try XCTUnwrap(StudioRenderer.frame(
            of: project(), atSource: 5, events: events(),
            sources: FrameSources(screen: try screen()), outputTime: 5))
        XCTAssertEqual(png(middle), png(plainMiddle), "the fade darkened the middle of the video")

        try write(opening, named: "studio-fade-in")
    }

    /// A frame rendered with no output time — a still, a thumbnail — carries no wash rather than
    /// guessing at one.
    func testWithoutAnOutputTimeThereIsNoWash() throws {
        var faded = project()
        faded.fadeIn = 1

        let unwashed = try XCTUnwrap(StudioRenderer.frame(
            of: faded, atSource: 0, events: events(),
            sources: FrameSources(screen: try screen())))
        let plain = try XCTUnwrap(StudioRenderer.frame(
            of: project(), atSource: 0, events: events(),
            sources: FrameSources(screen: try screen())))
        XCTAssertEqual(png(unwashed), png(plain))
    }

    // MARK: - Pictures

    /// A brought-in picture reaches the finished frame — the seam, not the layer.
    func testAMediaOverlayIsDrawn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("logo.png")
        let picture = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        picture.setFillColor(CGColor(red: 0.1, green: 0.9, blue: 0.4, alpha: 1))
        picture.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        let image = try XCTUnwrap(picture.makeImage())
        try XCTUnwrap(CaptureWriter.pngData(from: image)).write(to: file)

        var withPicture = project()
        withPicture.mediaOverlays = [MediaOverlay(start: 0, end: 10, asset: "logo.png")]
        let loaded = try XCTUnwrap(MediaStore.shared.image(at: file))

        let plain = try XCTUnwrap(StudioRenderer.frame(
            of: project(), atSource: 3, events: events(),
            sources: FrameSources(screen: try screen())))
        let composited = try XCTUnwrap(StudioRenderer.frame(
            of: withPicture, atSource: 3, events: events(),
            sources: FrameSources(screen: try screen(), media: ["logo.png": loaded])))

        XCTAssertNotEqual(png(plain), png(composited), "the picture was not drawn")
        try write(composited, named: "studio-media-overlay")
    }

    /// An overlay whose file is missing draws nothing rather than a black box — a project moved
    /// between Macs with a half-copied bundle should degrade, not break.
    func testAMissingPictureDrawsNothing() throws {
        var withPicture = project()
        withPicture.mediaOverlays = [MediaOverlay(start: 0, end: 10, asset: "gone.png")]

        XCTAssertEqual(png(try render(project(), at: 3)), png(try render(withPicture, at: 3)))
    }
}
