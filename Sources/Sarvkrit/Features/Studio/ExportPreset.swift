import AVFoundation
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A named set of export settings.
///
/// **Because "which of these numbers do I want" is not a question most people can answer.** The
/// individual controls are all still there; these are the four answers that cover almost every
/// reason somebody exports a screen recording.
struct ExportPreset: Identifiable, Equatable {

    enum Codec: String, Codable, CaseIterable, Equatable {
        case h264
        case hevc
        case proRes422
        case gif

        var title: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            case .proRes422: return "ProRes 422"
            case .gif: return "GIF"
            }
        }

        /// Said in the UI, because "smaller file" and "might not play" are the same choice.
        var caveat: String? {
            switch self {
            case .h264: return nil
            case .hevc: return "About half the size, but not everything can play it."
            case .proRes422: return "Very large. For handing to a video editor."
            case .gif: return "No sound, and large for anything over a few seconds."
            }
        }
    }

    var id: String
    var name: String
    /// One line under the name, so a preset is chosen by what it is for rather than by its numbers.
    var purpose: String
    var codec: Codec
    /// Target height in pixels; nil keeps the canvas as it is.
    var height: Int?
    /// Nil follows the recording's own rate.
    ///
    /// **A 30fps recording exported at 60 is every frame duplicated.** This was a plain `Int` and
    /// `manifest.fps` was read nowhere, so choosing 30fps when recording produced a 60fps file of
    /// pairs — twice the bitrate for the same pictures.
    var fps: Int?
    /// Whether a chosen height above the canvas is honoured rather than capped.
    ///
    /// **Off for a preset, on for a deliberate choice.** A preset must never upscale by accident —
    /// a 720p recording exported at 4K is a bigger file and not a better video — but somebody who
    /// picks 4K having been told it will upscale is not to be overridden.
    var allowsUpscale: Bool = false

    static let sharpest = ExportPreset(
        id: "sharpest", name: "Sharpest", purpose: "Every pixel that was recorded",
        codec: .h264, height: nil, fps: nil)
    static let web = ExportPreset(
        id: "web", name: "Web", purpose: "1080p — plays everywhere",
        codec: .h264, height: 1080, fps: 60)
    static let small = ExportPreset(
        id: "small", name: "Small", purpose: "720p — for sending in a message",
        codec: .h264, height: 720, fps: 30)
    static let forEditing = ExportPreset(
        id: "editing", name: "For an editor", purpose: "ProRes at full size — very large",
        codec: .proRes422, height: nil, fps: nil)

    /// Sharpest first: it is the one this app was throwing away for free.
    static let all: [ExportPreset] = [.sharpest, .web, .small, .forEditing]

    /// The rate to encode at, given what the recording was captured at.
    func frameRate(forRecording recordingFPS: Int) -> Int {
        fps ?? max(1, recordingFPS)
    }

    var fileType: AVFileType { codec == .proRes422 ? .mov : .mp4 }
    var contentType: UTType { codec == .proRes422 ? .quickTimeMovie : .mpeg4Movie }
    var fileExtension: String { codec == .proRes422 ? "mov" : "mp4" }

    /// Bits per second for a lossy codec.
    ///
    /// **The frame rate is a factor, and it was not.** This was `width × height × 8`, so 60fps and
    /// 30fps were handed the same budget and 60fps got half the quality per frame. Anchored at
    /// 30fps so the existing look of a 30fps export does not change.
    static func videoBitrate(size: CGSize, fps: Int) -> Int {
        let pixels = Double(size.width * size.height)
        return Int(pixels * 8 * (Double(max(1, fps)) / 30).squareRoot())
    }

    /// Roughly how large the file will be, for the dialog to show before committing.
    ///
    /// Deliberately rough: the audio is a fixed 128 kbps and ProRes is quoted from its data rate
    /// per megapixel rather than from a bitrate it does not have. A number within a factor of
    /// about 1.5 is what makes "will this fit in an email" answerable.
    func estimatedBytes(forCanvas canvas: CGSize, seconds: TimeInterval,
                        recordingFPS: Int) -> Int {
        let size = outputSize(forCanvas: canvas)
        let rate = frameRate(forRecording: recordingFPS)
        let videoBitsPerSecond: Double
        if codec == .proRes422 {
            // ProRes 422 is about 15 MB/s at 1080p30, and scales with pixels and rate.
            let megapixels = Double(size.width * size.height) / 2_073_600
            videoBitsPerSecond = 15_000_000 * 8 * megapixels * Double(rate) / 30
        } else {
            videoBitsPerSecond = Double(Self.videoBitrate(size: size, fps: rate))
        }
        let audioBitsPerSecond = 128_000.0
        return Int((videoBitsPerSecond + audioBitsPerSecond) * max(0, seconds) / 8)
    }

    /// The pixel size to encode at, for a given canvas.
    ///
    /// Two rules that are easy to get wrong and expensive to notice later:
    ///
    /// - **Never upscale.** A 720p recording exported at 4K is a bigger file and not a better
    ///   video, and the only thing it reliably produces is a long wait.
    /// - **Always even.** H.264 and HEVC work in macroblocks; an odd dimension makes the encoder
    ///   pad the frame, which costs quality for nothing and is invisible until somebody looks
    ///   closely at the last row of pixels.
    func outputSize(forCanvas canvas: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        guard let height, allowsUpscale || Double(height) < Double(canvas.height) else {
            return CGSize(width: Self.even(canvas.width), height: Self.even(canvas.height))
        }
        let scale = Double(height) / Double(canvas.height)
        return CGSize(width: Self.even(canvas.width * CGFloat(scale)),
                      height: Self.even(CGFloat(height)))
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

/// One row of the export dialog's resolution list.
///
/// **Named against the canvas, not in the abstract.** "1080p" means a different pixel size for
/// every recording, and whether it is a downscale or an upscale depends entirely on what was
/// captured — so each row carries the size it will actually produce and whether producing it means
/// inventing pixels.
struct ExportResolution: Identifiable, Equatable {

    enum Choice: Equatable, Hashable {
        case native
        case height(Int)
    }

    var id: Choice { resolution }
    let resolution: Choice
    let size: CGSize
    /// The composited canvas this row was measured against — the recording plus its background
    /// padding. Kept because the ratio between it and `size` is what says how much of the output
    /// frame the picture itself gets.
    let canvas: CGSize
    /// The canvas cannot fill this, so the encoder would be stretching it.
    let upscales: Bool

    var name: String {
        switch resolution {
        case .native: return "Native"
        case .height(2160): return "4K"
        case .height(let height): return "\(height)p"
        }
    }

    /// `3152 × 2092`, for the row's second line.
    var pixels: String { "\(Int(size.width)) × \(Int(size.height))" }

    /// How tall the *recording* itself ends up, which is not the frame height whenever the project
    /// has background padding.
    ///
    /// **The height cap measures the padded canvas.** With the default 64pt padding, "1080p" on a
    /// 3024×1964 capture puts the picture at about 1014 pixels — the number in the menu is not the
    /// number the content gets, and the dialog should be able to say so.
    func contentHeight(forRecording recording: CGSize) -> CGFloat {
        guard canvas.height > 0, recording.height > 0 else { return size.height }
        // The recording occupies its own share of the canvas, and the whole canvas is scaled to
        // the output height — so the picture keeps that share of the frame.
        return (recording.height * (size.height / canvas.height)).rounded()
    }

    /// The heights worth offering, largest first, each measured against this canvas.
    ///
    /// 4K is offered even where it upscales, because it was asked for and because a 4K container is
    /// sometimes what a downstream tool needs. It is marked rather than hidden.
    static func offered(forCanvas canvas: CGSize) -> [ExportResolution] {
        guard canvas.width > 0, canvas.height > 0 else { return [] }
        let native = ExportResolution(resolution: .native, size: even(canvas),
                                      canvas: canvas, upscales: false)
        let heights = [2160, 1440, 1080, 720]
        return [native] + heights.map { height in
            let scale = CGFloat(height) / canvas.height
            return ExportResolution(
                resolution: .height(height),
                size: even(CGSize(width: canvas.width * scale, height: CGFloat(height))),
                canvas: canvas,
                upscales: CGFloat(height) > canvas.height)
        }
    }

    private static func even(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (size.width / 2).rounded() * 2),
               height: max(2, (size.height / 2).rounded() * 2))
    }
}
