import AppKit
import CoreGraphics
import Foundation

/// The seven text styles, matching what the reference editor offers.
///
/// They are **not seven typefaces** — that reading costs you the half of the feature people
/// actually use. They are three typefaces crossed with four container treatments: bare, a white
/// halo for text over a busy screenshot, a filled box, and a bordered box. "Rounded Boxed" is a
/// capsule; "Monospaced Boxed" is a white field with a hairline border, which is what a code
/// snippet dropped on a screenshot wants to look like.
///
/// The preset is a *starting point*, never the truth. `TextElement` stores the resolved values, so
/// changing this table in a later release cannot restyle text somebody already wrote — the same
/// rule the element's own doc comment states.
enum TextPreset: String, CaseIterable, Identifiable, Codable {
    case standard
    case rounded
    case monospaced
    case outlined
    case boxed
    case roundedBoxed
    case monospacedBoxed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .rounded: return "Rounded"
        case .monospaced: return "Monospaced"
        case .outlined: return "Outlined"
        case .boxed: return "Boxed"
        case .roundedBoxed: return "Rounded Boxed"
        case .monospacedBoxed: return "Monospaced Boxed"
        }
    }

    var typeface: TextElement.Typeface {
        switch self {
        case .standard, .outlined, .boxed: return .standard
        case .rounded, .roundedBoxed: return .rounded
        case .monospaced, .monospacedBoxed: return .monospaced
        }
    }

    /// Whether the glyphs get a halo. Only `.outlined`, whose entire job is staying legible over
    /// a photograph without putting a box on it.
    var hasHalo: Bool { self == .outlined }

    var hasBackground: Bool {
        switch self {
        case .boxed, .roundedBoxed, .monospacedBoxed: return true
        case .standard, .rounded, .monospaced, .outlined: return false
        }
    }

    var hasBorder: Bool { self == .monospacedBoxed }

    /// A fraction of the font size, so a preset is resolution-independent — the corner of a capsule
    /// has to grow with the text or a 4× capture gets a box with almost square corners.
    var cornerRadiusFraction: CGFloat {
        switch self {
        case .roundedBoxed: return 0.9      // beyond half the padded height: a capsule
        case .boxed, .monospacedBoxed: return 0.12
        case .standard, .rounded, .monospaced, .outlined: return 0
        }
    }

    /// Applies the style, leaving the string, the origin and the size alone.
    ///
    /// **Foreground colour is deliberately untouched for the bare styles and forced dark for the
    /// boxed ones.** Red text on a red pill is unreadable, and the picked colour is more useful as
    /// the box than as glyphs nobody can see — which is what the reference does.
    func apply(to text: inout TextElement, accent: RGBAColour) {
        text.presetID = rawValue
        text.typeface = typeface
        text.haloColour = hasHalo ? .white : nil
        text.borderColour = hasBorder ? RGBAColour(r: 0.15, g: 0.15, b: 0.17) : nil
        text.cornerRadius = text.fontSize * cornerRadiusFraction

        if hasBackground {
            text.background = self == .monospacedBoxed ? .white : accent
            text.colour = self == .monospacedBoxed
                ? RGBAColour(r: 0.11, g: 0.11, b: 0.13)
                : accent.readableForeground
            text.padding = text.fontSize * 0.28
        } else {
            text.background = nil
            text.colour = accent
            text.padding = 0
        }
    }

    /// A `TextElement` styled by this preset, for previews and for the first text of a session.
    func sample(_ string: String, at origin: CGPoint = .zero,
                fontSize: CGFloat, accent: RGBAColour) -> TextElement {
        var element = TextElement(origin: origin, string: string, fontSize: fontSize)
        apply(to: &element, accent: accent)
        return element
    }
}

extension TextElement.Typeface {
    /// Resolved through the system's own APIs rather than by name.
    ///
    /// `NSFont(name:)` on a system font's PostScript name is unreliable — the names are private and
    /// have changed between macOS releases — so a document written on one Mac could open with a
    /// fallback face on another. `.custom` is the only case that goes through a name, because there
    /// the name is the user's actual choice.
    func font(ofSize size: CGFloat, customName: String?) -> NSFont {
        switch self {
        case .standard:
            return .systemFont(ofSize: size, weight: .bold)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded),
                  let font = NSFont(descriptor: descriptor, size: size) else { return base }
            return font
        case .monospaced:
            // Semibold, not medium: a monospaced face at the same nominal weight reads lighter than
            // the proportional one beside it, and a caption on a screenshot has to hold up against
            // whatever is behind it.
            return .monospacedSystemFont(ofSize: size, weight: .semibold)
        case .custom:
            guard let customName, let font = NSFont(name: customName, size: size) else {
                return .systemFont(ofSize: size, weight: .bold)
            }
            return font
        }
    }
}

extension RGBAColour {
    /// Black or white, whichever can be read on top of this colour.
    ///
    /// Rec. 601 luma rather than plain lightness: the eye is far more sensitive to green than to
    /// blue, so an average puts the flip in the wrong place and yellow ends up with white text.
    var readableForeground: RGBAColour {
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        return luma > 0.6
            ? RGBAColour(r: 0.09, g: 0.09, b: 0.11)
            : .white
    }
}
