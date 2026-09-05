import CoreGraphics
import Foundation

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
    var codec: Codec
    /// Target height in pixels; nil keeps the canvas as it is.
    var height: Int?
    var fps: Int
    /// Social video is watched muted more often than not.
    var forcesCaptions: Bool = false
    /// Keeps the microphone and system audio as separate tracks in the container.
    var separatesAudioTracks: Bool = false

    static let web = ExportPreset(id: "web", name: "Web", codec: .h264, height: 1080, fps: 60)
    static let social = ExportPreset(id: "social", name: "Social", codec: .h264, height: 1080,
                                     fps: 30, forcesCaptions: true)
    static let forEditing = ExportPreset(id: "editing", name: "For an editor", codec: .proRes422,
                                         height: nil, fps: 60, separatesAudioTracks: true)
    static let small = ExportPreset(id: "small", name: "Small", codec: .h264, height: 720, fps: 30)

    static let all: [ExportPreset] = [.web, .social, .forEditing, .small]

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
        guard let height, Double(height) < Double(canvas.height) else {
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
