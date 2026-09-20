import Foundation

/// What a click looks like in the finished video.
///
/// The recording has no cursor in it at all, so a click leaves no visible trace unless one is
/// drawn — which is the opportunity, not the problem: the effect can be chosen, restyled and
/// switched off long after the recording was made.
enum ClickEffectStyle: String, Codable, CaseIterable, Equatable {
    /// An expanding ring. The default: visible without being loud.
    case ripple
    /// A soft filled disc that fades.
    case highlight
    /// The pointer itself dips and returns. **The subtle one** — it reads as "the mouse was
    /// pressed" rather than as "an effect played", which is what you want in a serious demo.
    case shrink
    case none

    var title: String {
        switch self {
        case .ripple: return "Ripple"
        case .highlight: return "Highlight"
        case .shrink: return "Shrink"
        case .none: return "None"
        }
    }
}

/// What to draw for a click, at one moment.
///
/// Radii are multiples of the cursor's own size, so an effect stays in proportion when the pointer
/// is scaled up — an absolute radius looks enormous beside a small cursor and lost beside a large
/// one.
struct ClickEffectState: Equatable {
    var ringRadius: Double = 0
    var ringAlpha: Double = 0
    var fillAlpha: Double = 0
    /// Multiplier on the cursor glyph.
    var cursorScale: Double = 1
}

enum ClickEffect {
    /// Long enough to register, short enough not to still be on screen at the next click. Faster
    /// than this and it flickers; slower and a double-click leaves two rings overlapping.
    static let duration: TimeInterval = 0.32

    /// How far a ripple travels, as a multiple of the cursor's height.
    static let ringExtent: Double = 2.4

    /// Nil means draw nothing — before the click, after the effect, or for `.none`. A caller that
    /// gets nil has no branch to write.
    static func state(_ style: ClickEffectStyle, secondsSinceClick t: TimeInterval)
        -> ClickEffectState? {
        guard style != .none, t >= 0, t <= duration else { return nil }
        let progress = duration > 0 ? t / duration : 1

        switch style {
        case .none:
            return nil
        case .ripple:
            // Eased outward and faded on a square, so it thins as it grows the way a real
            // disturbance in a surface does. A linear fade stays visible right up to the moment it
            // vanishes, which reads as a dropped frame.
            let remaining = 1 - progress
            return ClickEffectState(ringRadius: ringExtent * ZoomEase.smooth.value(progress),
                                    ringAlpha: remaining * remaining)
        case .highlight:
            return ClickEffectState(ringRadius: ringExtent * 0.55,
                                    fillAlpha: 0.35 * pow(1 - progress, 1.5))
        case .shrink:
            // One smooth dip and back. Nothing is drawn but the cursor itself.
            return ClickEffectState(cursorScale: 1 - 0.15 * sin(.pi * progress))
        }
    }
}
