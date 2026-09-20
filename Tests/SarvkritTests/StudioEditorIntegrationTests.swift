import AVFoundation
import AppKit
import CoreMedia
import XCTest
@testable import Sarvkrit

/// The editor, assembled the way the app assembles it, over a recording long enough to be real.
///
/// **This suite exists because I could not press the button.** Play and the seekbar were both
/// reported dead, twice, and this machine refuses synthetic input — so every previous round verified
/// the transport by reasoning rather than by driving it. This drives it: the real window controller,
/// the real view hierarchy, the real clock, through the same call the Play button's action makes.
///
/// **And it is thirty seconds, not one.** Every other test in this feature uses a one- or two-second
/// clip, which is why nothing had ever exercised a seek that has real decoding to do between
/// keyframes — precisely the case a scrub hits.
///
/// **What this suite deliberately does not assert: the picture.** `AVPlayerItemVideoOutput` delivers
/// no frames in this test host — not even the opening one, which the running app plainly does show —
/// so a pixel assertion here would fail for reasons that have nothing to do with the code. Decoded
/// pixels are covered where they can be, by `StudioExportTests`, and the on-screen picture is
/// verified by driving the running app through `sarvkrit://seek`.
final class StudioEditorIntegrationTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editor-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private static let seconds: Double = 30
    private static let fps = 30

    /// A real, decodable recording of `seconds` length, with a moving picture so one frame can be
    /// told from another.
    private func makeRecording() async throws -> RecordingBundle {
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("r.sarvrec"))
        let size = CGSize(width: 320, height: 240)
        let writer = try RecordingWriter(url: bundle.screenURL, size: size, fps: Self.fps)

        for index in 0..<Int(Self.seconds * Double(Self.fps)) {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                // Ramps across the whole length, so any two moments differ.
                memset(base, Int32(20 + (index * 200) / Int(Self.seconds * Double(Self.fps))),
                       CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            var format: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                         formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(Self.fps)),
                presentationTimeStamp: CMTime(seconds: Double(index) / Double(Self.fps),
                                              preferredTimescale: 600),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescription: try XCTUnwrap(format),
                                                     sampleTiming: &timing,
                                                     sampleBufferOut: &sample)
            writer.append(try XCTUnwrap(sample))
        }
        await writer.finish()

        var manifest = RecordingManifest(source: .display, pixelSize: size,
                                         pointPixelScale: 1, fps: Self.fps)
        manifest.state = .complete
        manifest.duration = Self.seconds
        try bundle.write(manifest)
        try bundle.writeEvents(EventLog())
        return bundle
    }

    /// Everything the app builds when a recording finishes, including a shown window — which is what
    /// makes the clock and the decoder behave as they do in use.
    @MainActor
    private func openEditor(over bundle: RecordingBundle) throws
        -> (StudioDocumentModel, StudioEditorWindowController) {
        let manifest = try bundle.readManifest()
        let events = (try? bundle.readEvents()) ?? EventLog()
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: events)
        let controller = StudioEditorWindowController(model: model) { _ in }
        controller.show()
        return (model, controller)
    }

    private func pump(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// **Play.** The same call the button's action makes, on the real window.
    @MainActor
    func testPlayAdvancesThePlayheadInARealEditorWindow() async throws {
        let bundle = try await makeRecording()
        let (model, _) = try openEditor(over: bundle)
        defer { model.player.pause() }

        XCTAssertEqual(model.playhead, 0)
        model.player.toggle()
        XCTAssertTrue(model.player.isPlaying, "the transport refused to start")

        pump(3) { model.playhead > 0.5 }
        model.player.pause()

        XCTAssertGreaterThan(model.playhead, 0.4,
                             "the playhead did not move, so playback does nothing visible")
    }

    /// The playhead itself must land where it was asked to, at the far end of a long recording.
    @MainActor
    func testScrubbingNearTheEndLandsWhereAsked() async throws {
        let bundle = try await makeRecording()
        let (model, _) = try openEditor(over: bundle)
        defer { model.player.pause() }

        model.player.scrub(to: Self.seconds - 0.5)
        XCTAssertEqual(model.playhead, Self.seconds - 0.5, accuracy: 0.01)

        // And past the end clamps rather than running away.
        model.player.scrub(to: Self.seconds + 10)
        XCTAssertEqual(model.playhead, Self.seconds, accuracy: 0.01)
    }

}
