import AVFoundation
import CoreGraphics
import XCTest
@testable import Sarvkrit

/// What the export is allowed to come out as.
///
/// **Every export was 1080p and nothing said otherwise.** A frame pulled out of a real export of a
/// 3024×1964 recording measured 1662×1080 — the capture is at the display's full backing
/// resolution and the export threw away 45% of it linearly. The cause was one literal:
/// `StudioEditorWindowController` passed `preset: .web`, and `.web` is `height: 1080`. Both the
/// Export button and `sarvkrit://export` funnelled through it, and three of the four presets were
/// constructed nowhere outside tests.
final class ExportChoiceTests: XCTestCase {

    /// A stand-in for a padded canvas: taller and wider than the recording inside it.
    ///
    /// **Not the exact canvas a 3024×1964 capture produces** — that is about 3221×2092, because
    /// `.original` aspect widens the padded 3152×2092 back to the recording's own ratio, which is
    /// also why the old export came out 1662 wide rather than 1628. The arithmetic under test does
    /// not care which canvas it is handed; the live pass measures the real one.
    private let canvas = CGSize(width: 3152, height: 2092)

    // MARK: - Native means native

    /// The whole point of the round: the sharpest export keeps every pixel that was recorded.
    func testTheSharpestPresetKeepsTheWholeCanvas() {
        XCTAssertEqual(ExportPreset.sharpest.outputSize(forCanvas: canvas), canvas)
    }

    func testTheSharpestPresetUsesTheRecordingsOwnFrameRate() {
        XCTAssertNil(ExportPreset.sharpest.fps,
                     "nil means the recording's own rate; a fixed number would resample it")
    }

    /// **A 30fps recording exported at 60 is every frame duplicated.** `preset.fps` was always
    /// taken literally and `manifest.fps` was never read, so choosing 30fps in the recording
    /// settings produced a 60fps file of pairs.
    func testAPresetWithNoFrameRateFollowsTheRecording() {
        XCTAssertEqual(ExportPreset.sharpest.frameRate(forRecording: 30), 30)
        XCTAssertEqual(ExportPreset.sharpest.frameRate(forRecording: 60), 60)
    }

    func testAPresetWithItsOwnFrameRateKeepsIt() {
        XCTAssertEqual(ExportPreset.small.frameRate(forRecording: 60), 30)
    }

    // MARK: - Upscaling is offered, and only when asked for

    /// A preset must never upscale by accident: a 720p recording exported at 4K is a bigger file
    /// and not a better video.
    func testAPresetNeverUpscalesOnItsOwn() {
        let small = CGSize(width: 640, height: 360)
        XCTAssertEqual(ExportPreset.web.outputSize(forCanvas: small).height, 360, accuracy: 1)
    }

    /// **But a deliberate choice is not overridden.** 4K is offered for a 2092-tall canvas because
    /// it was asked for, and the dialog says it will upscale rather than silently capping.
    func testADeliberateUpscaleIsHonoured() {
        var chosen = ExportPreset.web
        chosen.height = 2160
        chosen.allowsUpscale = true
        XCTAssertEqual(chosen.outputSize(forCanvas: canvas).height, 2160, accuracy: 1)
    }

    func testTheSameChoiceWithoutPermissionStillCaps() {
        var chosen = ExportPreset.web
        chosen.height = 2160
        XCTAssertEqual(chosen.outputSize(forCanvas: canvas).height, canvas.height, accuracy: 1)
    }

    func testAnUpscaleKeepsTheAspect() {
        var chosen = ExportPreset.web
        chosen.height = 2160
        chosen.allowsUpscale = true
        let size = chosen.outputSize(forCanvas: canvas)
        XCTAssertEqual(size.width / size.height, canvas.width / canvas.height, accuracy: 0.01)
    }

    func testEveryOutputSizeIsEven() {
        for preset in ExportPreset.all {
            let size = preset.outputSize(forCanvas: CGSize(width: 1919, height: 1081))
            XCTAssertEqual(Int(size.width) % 2, 0, preset.name)
            XCTAssertEqual(Int(size.height) % 2, 0, preset.name)
        }
    }

    // MARK: - The offered list

    /// Named against the canvas, so the menu says the pixels it will actually produce rather than
    /// a label that means something different for every recording.
    func testTheResolutionListNamesRealPixelSizes() {
        let offered = ExportResolution.offered(forCanvas: canvas)
        XCTAssertEqual(offered.first?.resolution, ExportResolution.Choice.native)
        XCTAssertEqual(offered.first?.size, canvas)
        XCTAssertTrue(offered.contains { $0.resolution == ExportResolution.Choice.height(2160) })
        XCTAssertTrue(offered.contains { $0.resolution == ExportResolution.Choice.height(1080) })
    }

    /// Anything above the canvas is marked, because that is the difference between a bigger file
    /// and a better video.
    func testASizeAboveTheCanvasIsMarkedAsUpscaled() {
        let offered = ExportResolution.offered(forCanvas: canvas)
        let fourK = offered.first { $0.resolution == ExportResolution.Choice.height(2160) }
        XCTAssertEqual(fourK?.upscales, true)
        let hd = offered.first { $0.resolution == ExportResolution.Choice.height(1080) }
        XCTAssertEqual(hd?.upscales, false)
        XCTAssertEqual(offered.first?.upscales, false, "native never upscales")
    }

    /// **Padding costs resolution off the picture.** The height cap measures the padded canvas, so
    /// "1080p" on a 3152×2092 canvas puts the recording's own content at about 1014 pixels. The
    /// dialog has to be able to say so.
    func testTheContentHeightIsReportedSeparatelyFromTheFrameHeight() {
        let offered = ExportResolution.offered(forCanvas: canvas)
        let hd = try? XCTUnwrap(offered.first { $0.resolution == ExportResolution.Choice.height(1080) })
        XCTAssertEqual(hd?.contentHeight(forRecording: CGSize(width: 3024, height: 1964)) ?? 0,
                       1014, accuracy: 2)
    }

    /// And says nothing when there is nothing to say — an unpadded canvas loses none.
    func testAnUnpaddedCanvasLosesNothingToPadding() {
        let unpadded = CGSize(width: 3024, height: 1964)
        let offered = ExportResolution.offered(forCanvas: unpadded)
        let native = try? XCTUnwrap(offered.first)
        XCTAssertEqual(native?.contentHeight(forRecording: unpadded) ?? 0, 1964, accuracy: 1)
    }

    // MARK: - The container follows the codec

    /// The save panel offered only `.mpeg4Movie` while the exporter writes `.mov` for ProRes, so
    /// choosing the editor preset would have produced a file the panel would not name.
    func testTheFileTypeFollowsTheCodec() {
        XCTAssertEqual(ExportPreset.web.fileType, .mp4)
        XCTAssertEqual(ExportPreset.forEditing.fileType, .mov)
        XCTAssertEqual(ExportPreset.web.contentType, .mpeg4Movie)
        XCTAssertEqual(ExportPreset.forEditing.contentType, .quickTimeMovie)
    }

    func testTheFileExtensionFollowsTheCodecToo() {
        XCTAssertEqual(ExportPreset.web.fileExtension, "mp4")
        XCTAssertEqual(ExportPreset.forEditing.fileExtension, "mov")
    }

    // MARK: - Bitrate

    /// **The bitrate ignored the frame rate**, so 60fps and 30fps were given the same budget and
    /// 60fps quietly got half the quality per frame.
    func testTheBitrateRisesWithTheFrameRate() {
        let size = CGSize(width: 1920, height: 1080)
        let slow = ExportPreset.videoBitrate(size: size, fps: 30)
        let fast = ExportPreset.videoBitrate(size: size, fps: 60)
        XCTAssertGreaterThan(fast, slow)
    }

    func testTheBitrateRisesWithTheFrameSize() {
        XCTAssertGreaterThan(
            ExportPreset.videoBitrate(size: CGSize(width: 3840, height: 2160), fps: 60),
            ExportPreset.videoBitrate(size: CGSize(width: 1920, height: 1080), fps: 60))
    }

    /// A 4K 60fps H.264 stream at a sane rate, so the estimate the dialog shows is not nonsense.
    func testAFourKBitrateIsInAPlausibleRange() {
        let rate = ExportPreset.videoBitrate(size: CGSize(width: 3840, height: 2160), fps: 60)
        XCTAssertGreaterThan(rate, 20_000_000)
        XCTAssertLessThan(rate, 200_000_000)
    }

    // MARK: - Saying how big it will be

    func testTheEstimateGrowsWithDuration() {
        let short = ExportPreset.web.estimatedBytes(forCanvas: canvas, seconds: 10, recordingFPS: 60)
        let long = ExportPreset.web.estimatedBytes(forCanvas: canvas, seconds: 60, recordingFPS: 60)
        XCTAssertGreaterThan(long, short * 4)
    }

    func testTheEstimateIsLargerForTheSharperPreset() {
        XCTAssertGreaterThan(
            ExportPreset.sharpest.estimatedBytes(forCanvas: canvas, seconds: 30, recordingFPS: 60),
            ExportPreset.small.estimatedBytes(forCanvas: canvas, seconds: 30, recordingFPS: 60))
    }

    // MARK: - Every preset is reachable and honest

    /// `.social` promised burnt-in captions through a `forcesCaptions` flag that nothing read, and
    /// `.forEditing` promised split audio tracks through another. Both are gone rather than
    /// wired up: captions already burn in whenever the project has them, so the preset could only
    /// have promised something it does not do.
    func testEveryPresetIsOfferedAndDistinct() {
        XCTAssertEqual(Set(ExportPreset.all.map(\.id)).count, ExportPreset.all.count)
        XCTAssertTrue(ExportPreset.all.contains { $0.id == ExportPreset.sharpest.id })
        XCTAssertTrue(ExportPreset.all.contains { $0.id == ExportPreset.forEditing.id })
    }

    /// The default is the one that plays everywhere, not the one that is technically best.
    func testTheDefaultPresetIsPlayableEverywhere() {
        XCTAssertEqual(ExportPreset.web.codec, .h264)
    }
}
