import CoreGraphics
import Foundation

/// A gradient, described rather than drawn.
///
/// **The built-in backgrounds are data, not image assets.** Twenty PNGs large enough for a 6K
/// canvas would add tens of megabytes to a menu-bar utility, be wrong at every aspect ratio other
/// than the one they were drawn at, and need @2x variants. Gradients resample perfectly and render
/// in about a millisecond.
struct GradientSpec: Codable, Equatable {
    enum Kind: String, Codable, Equatable { case linear, radial }

    struct Stop: Codable, Equatable {
        var colour: RGBAColour
        var location: Double
    }

    var stops: [Stop]
    /// Degrees, clockwise from the top. Ignored for a radial.
    var angle: Double = 135
    var kind: Kind = .linear
}

/// A mesh gradient: a grid of colours blended between.
///
/// **Why a grid and not more stops on a line.** Every built-in used to be two stops at 135°, and
/// a line through colour space cannot hold what the good ones do — one of the reference's runs
/// blue through amber to peach, another purple through cyan to violet. Those need colour to vary
/// in *two* directions, which is a grid.
///
/// Row-major, `columns × rows` entries. Not fixed at 3×3: the renderer interpolates whatever it
/// is given, and a future preset wanting finer control should not need a new type.
struct MeshSpec: Codable, Equatable {
    var columns: Int
    var rows: Int
    var colours: [RGBAColour]

    init(columns: Int, rows: Int, colours: [RGBAColour]) {
        self.columns = max(2, columns)
        self.rows = max(2, rows)
        self.colours = colours
    }

    /// True when the grid actually holds the colours it claims to.
    ///
    /// Checked rather than trusted because a `Codable` value arrives from a file, and a short
    /// array would otherwise be an index-out-of-range at draw time.
    var isWellFormed: Bool { colours.count == columns * rows && columns >= 2 && rows >= 2 }

    func colour(column: Int, row: Int) -> RGBAColour {
        let c = min(max(column, 0), columns - 1)
        let r = min(max(row, 0), rows - 1)
        let index = r * columns + c
        return colours.indices.contains(index) ? colours[index] : .white
    }
}

/// What surrounds a screenshot.
///
/// **Not `BackgroundStyle`, which is what this was called first.** SwiftUI ships a type of that
/// name, so in any file importing SwiftUI the bare initialiser was ambiguous — it compiled
/// wherever the contextual type happened to disambiguate it and failed the moment one didn't.
struct CaptureBackground: Codable, Equatable {
    enum Fill: Equatable {
        case none
        case solid(RGBAColour)
        case gradient(GradientSpec)
        case mesh(MeshSpec)
        /// Resolved through `BackgroundCatalogue`. Stored by id so a catalogue tweak reaches
        /// existing documents.
        case builtIn(id: String)
        /// A user image, copied into the store — a filename, never a path that can move.
        case image(fileName: String)
        /// A fill written by a newer build. Held verbatim and written back unchanged.
        case unknown(type: String, raw: Data)
    }

    struct Shadow: Codable, Equatable {
        var radius: CGFloat = 40
        var offsetY: CGFloat = 20
        var opacity: Double = 0.35
        var colour: RGBAColour = .black
    }

    var fill: Fill = .builtIn(id: "dusk")
    /// Image pixels.
    var padding: CGFloat = 64
    var cornerRadius: CGFloat = 16
    var shadow: Shadow? = Shadow()
    /// Letterboxing target for the finished canvas.
    var aspect: AspectRatio = .original
    /// Gap between images when the combiner uses this style.
    var spacing: CGFloat = 24
    var isAutoBalanced: Bool = false
}

/// Aspect presets, shared by the crop tool and the background tool.
enum AspectRatio: String, Codable, CaseIterable, Identifiable, Equatable {
    case free
    case original
    case square
    case fourThree
    case threeTwo
    case sixteenNine
    case nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    /// width ÷ height, or nil when the ratio isn't fixed.
    func value(originalSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original:
            guard originalSize.height > 0 else { return nil }
            return originalSize.width / originalSize.height
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}
