import CoreGraphics
import Foundation

/// sRGB, 0…1.
///
/// Not `NSColor`: a document has to decode identically on another Mac, and an archived `NSColor`
/// carries a colour space and a catalog name that may not resolve there.
struct RGBAColour: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let red = RGBAColour(r: 1, g: 0.23, b: 0.19)
    static let orange = RGBAColour(r: 1, g: 0.58, b: 0)
    static let yellow = RGBAColour(r: 1, g: 0.8, b: 0)
    static let green = RGBAColour(r: 0.2, g: 0.78, b: 0.35)
    static let blue = RGBAColour(r: 0, g: 0.48, b: 1)
    static let purple = RGBAColour(r: 0.69, g: 0.32, b: 0.87)
    static let white = RGBAColour(r: 1, g: 1, b: 1)
    static let black = RGBAColour(r: 0, g: 0, b: 0)

    /// The 1–6 palette.
    static let palette: [RGBAColour] = [.red, .orange, .yellow, .green, .blue, .purple]
}

struct StrokeStyle: Codable, Equatable {
    var colour: RGBAColour = .red
    /// **Image pixels, not points.** On a 2x capture a 4pt-looking arrow is 8 — see
    /// `AnnotationDocument.scale`.
    var width: CGFloat = 6
    var dash: [CGFloat]?
}

// MARK: - Per-tool payloads
//
// All geometry is in image pixels, top-left origin. Said once on `AnnotationDocument` and true
// everywhere below.

struct ArrowElement: Codable, Equatable {
    enum Head: String, Codable, Equatable, CaseIterable {
        case filled, open, thin, curved
    }
    var start: CGPoint
    var end: CGPoint
    /// Perpendicular offset of the Bézier control point from the chord midpoint, in pixels.
    /// Zero for the three straight styles.
    var curvature: CGFloat = 0
    var head: Head = .filled
    var stroke = StrokeStyle()
}

struct LineElement: Codable, Equatable {
    var start: CGPoint
    var end: CGPoint
    var stroke = StrokeStyle()
}

struct ShapeElement: Codable, Equatable {
    var rect: CGRect
    var stroke = StrokeStyle()
    /// Nil for an outline. An outlined shape hit-tests on its edge only — see `AnnotationGeometry`.
    var fill: RGBAColour?
    var cornerRadius: CGFloat = 0
}

struct TextElement: Codable, Equatable {
    var origin: CGPoint
    var maxWidth: CGFloat?
    var string: String = ""
    /// Which preset it came from, for "reset to style". A hint only.
    var presetID: String?
    /// **Resolved, and this is the truth.** The preset table can change between releases and a
    /// font can be missing on another Mac; storing the resolved values means a reopened document
    /// renders as it was written.
    var fontName: String = "Helvetica-Bold"
    var fontSize: CGFloat = 36
    var colour: RGBAColour = .red
    var background: RGBAColour?
    var padding: CGFloat = 6
}

struct HighlightElement: Codable, Equatable {
    var rect: CGRect
    var colour: RGBAColour = .yellow
    /// True when the bar was snapped to a Vision-detected line, so the inspector can offer to
    /// unsnap and a re-layout can re-snap.
    var snappedToText: Bool = false
}

struct PencilElement: Codable, Equatable {
    /// Already simplified by `PencilSmoothing.simplify`; rendering fits a curve through these.
    var points: [CGPoint]
    var stroke = StrokeStyle()
}

struct SpotlightElement: Codable, Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat = 8
    var dimming: Double = 0.6
    var isEllipse: Bool = false
}

struct CounterElement: Codable, Equatable {
    var centre: CGPoint
    var radius: CGFloat = 22
    /// Assigned by `AnnotationDocument.renumberCounters()`, never by hand.
    var number: Int = 1
    var fill: RGBAColour = .red
    var textColour: RGBAColour = .white
}

struct PixelFilterElement: Codable, Equatable {
    enum Mode: String, Codable, Equatable, CaseIterable {
        /// Cosmetic. A linear convolution, and therefore reversible — see `PixelFilters`.
        case smoothBlur
        /// Carries no information beyond the region's mean colour.
        case secureBlur
        case pixellate

        var title: String {
            switch self {
            case .smoothBlur: return "Blur (smooth)"
            case .secureBlur: return "Blur (secure)"
            case .pixellate: return "Pixelate"
            }
        }

        /// Whether this mode may be described to the user as hiding anything.
        var isSecure: Bool { self == .secureBlur }
    }

    var rect: CGRect
    var isEllipse: Bool = false
    var mode: Mode = .secureBlur
    /// Blur sigma, or pixellate cell size. Image pixels.
    var radius: CGFloat = 24
    /// Frozen randomisation, so a reopened document renders identically instead of re-jittering.
    var seed: UInt64 = 0x5eed
}

struct EmojiElement: Codable, Equatable {
    var rect: CGRect
    var emoji: String = "👍"
}

/// One annotation.
struct AnnotationElement: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Painter's order. Carried explicitly so reordering is an edit to an element rather than a
    /// permutation of an array, which an undo snapshot can describe but a diff cannot.
    var z: Int = 0
    var kind: Kind

    enum Kind: Equatable {
        case arrow(ArrowElement)
        case line(LineElement)
        case rectangle(ShapeElement)
        case ellipse(ShapeElement)
        case text(TextElement)
        case highlighter(HighlightElement)
        case pencil(PencilElement)
        case spotlight(SpotlightElement)
        case counter(CounterElement)
        case blur(PixelFilterElement)
        case pixelate(PixelFilterElement)
        case emoji(EmojiElement)
        /// Written by a newer build. Held verbatim and written back unchanged.
        case unknown(type: String, raw: Data)
    }

    var isUnknown: Bool {
        if case .unknown = kind { return true }
        return false
    }

    init(id: UUID = UUID(), z: Int = 0, kind: Kind) {
        self.id = id
        self.z = z
        self.kind = kind
    }

    private enum Keys: String, CodingKey { case id, z, kind }

    /// Hand-written for the same reason as `AnnotationDocument`'s: a missing key must take the
    /// default rather than throwing, or an older file stops opening the moment a field is added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        z = try container.decodeIfPresent(Int.self, forKey: .z) ?? 0
        kind = try container.decode(Kind.self, forKey: .kind)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(z, forKey: .z)
        try container.encode(kind, forKey: .kind)
    }
}
