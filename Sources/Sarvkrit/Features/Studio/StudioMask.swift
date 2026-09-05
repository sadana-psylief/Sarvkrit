import CoreGraphics
import Foundation

/// A region hidden — or emphasised — for a stretch of the recording.
///
/// **This is where Sarvkrit is already ahead of what it is copying, and it should stay that way.**
/// The README argues at length that an ordinary blur is a linear convolution and therefore
/// invertible, and that pixelation is recoverable when the alphabet is small — which is exactly the
/// password case. `PixelFilterElement` already implements a `secureBlur` that keeps nothing but the
/// region's mean colour, with texture generated from a seed rather than from the pixels. That model
/// and that argument transfer to video unchanged; a mask gains a start and an end and nothing else.
struct StudioMask: Codable, Equatable, Identifiable {

    enum Mode: String, Codable, CaseIterable, Equatable {
        /// Keeps nothing but the region's mean colour. The default, and the only one safe over a
        /// credential.
        case secureBlur
        case smoothBlur
        case pixellate
        case solid
        /// The inverse: dims everything *outside* the region. `SpotlightElement` with a time range.
        case highlight

        var title: String {
            switch self {
            case .secureBlur: return "Secure blur"
            case .smoothBlur: return "Blur"
            case .pixellate: return "Pixelate"
            case .solid: return "Solid"
            case .highlight: return "Highlight"
            }
        }

        /// Said in the UI, because "blur" and "safe to share" are not the same claim.
        var caveat: String? {
            switch self {
            case .secureBlur, .solid, .highlight: return nil
            case .smoothBlur: return "Reversible. Don't use it over a password."
            case .pixellate: return "Recoverable for short text. Don't use it over a password."
            }
        }
    }

    var id = UUID()
    var mode: Mode = .secureBlur
    /// Several, sharing one time range: "hide every price in this table" is one object rather than
    /// nine to keep in sync.
    var rects: [RectBox]
    var isEllipse = false
    var start: TimeInterval
    var end: TimeInterval
    var blurRadius: Double = 24
    /// Texture for `secureBlur` comes from this, never from the pixels underneath.
    var seed: UInt64 = UInt64.random(in: 0...UInt64.max)
    var dimming: Double = 0.6

    /// Pins the mask to a window, so a sidebar stays covered through a whole demo without
    /// keyframing it by hand.
    var followsWindowID: UInt32?
    var windowOriginAtCreation: CGPoint?

    init(mode: Mode = .secureBlur, rects: [CGRect], start: TimeInterval, end: TimeInterval) {
        self.mode = mode
        self.rects = rects.map(RectBox.init)
        self.start = start
        self.end = end
    }

    func covers(_ t: TimeInterval) -> Bool { t >= start && t <= end }

    /// Moves a pinned mask to wherever its window is now.
    ///
    /// **A mask whose window has gone stays exactly where it is and stays opaque.** Uncovering
    /// what it was hiding because the thing moved is the one outcome that must never happen, so the
    /// missing case returns the mask unchanged rather than removing it or clearing its rects.
    func resolved(windowFrames: [UInt32: CGRect], recordingSize: CGSize) -> StudioMask {
        guard let followsWindowID,
              let origin = windowOriginAtCreation,
              let frame = windowFrames[followsWindowID] else { return self }

        let delta = CGPoint(x: frame.origin.x - origin.x, y: frame.origin.y - origin.y)
        var moved = self
        moved.rects = rects.map {
            RectBox(CGRect(x: $0.x + delta.x, y: $0.y + delta.y, width: $0.width, height: $0.height))
        }
        return moved
    }
}
