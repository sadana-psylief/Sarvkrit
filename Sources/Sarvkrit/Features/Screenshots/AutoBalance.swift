import CoreGraphics
import Foundation

/// Choosing a background that suits the screenshot.
///
/// "Auto Balance" is under-specified by the marketing it comes from, so this is a concrete
/// definition: **look at the screenshot's own colour and its content bounds, then pick a
/// background that contrasts with it and padding that looks even rather than measures even.**
///
/// Every step is pure over a small downsampled grid, so the taste can be adjusted without
/// touching anything that draws.
enum AutoBalance {

    /// A tiny downsample of an image: RGB triples in row-major order.
    struct Grid: Equatable {
        let width: Int
        let height: Int
        /// One `(r, g, b)` per cell, 0…1.
        let cells: [(r: Double, g: Double, b: Double)]

        static func == (a: Grid, b: Grid) -> Bool {
            a.width == b.width && a.height == b.height
                && zip(a.cells, b.cells).allSatisfy { $0 == $1 }
        }

        func cell(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
            cells[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }

        func luma(x: Int, y: Int) -> Double {
            let c = cell(x: x, y: y)
            return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        }
    }

    /// Where the actual content is, as a fraction of the image.
    ///
    /// Rows and columns whose variance is below `tolerance` at the edges are uniform margin — the
    /// screenshot already has whitespace there, so padding on that side can be reduced to make the
    /// composite look optically even rather than mathematically even.
    static func contentBounds(_ grid: Grid, tolerance: Double = 0.005) -> CGRect {
        guard grid.width > 0, grid.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }

        func rowIsFlat(_ y: Int) -> Bool {
            let values = (0..<grid.width).map { grid.luma(x: $0, y: y) }
            return variance(values) < tolerance
        }
        func columnIsFlat(_ x: Int) -> Bool {
            let values = (0..<grid.height).map { grid.luma(x: x, y: $0) }
            return variance(values) < tolerance
        }

        var top = 0
        while top < grid.height - 1, rowIsFlat(top) { top += 1 }
        var bottom = grid.height - 1
        while bottom > top, rowIsFlat(bottom) { bottom -= 1 }
        var left = 0
        while left < grid.width - 1, columnIsFlat(left) { left += 1 }
        var right = grid.width - 1
        while right > left, columnIsFlat(right) { right -= 1 }

        return CGRect(x: Double(left) / Double(grid.width),
                      y: Double(top) / Double(grid.height),
                      width: Double(right - left + 1) / Double(grid.width),
                      height: Double(bottom - top + 1) / Double(grid.height))
    }

    private static func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    /// The screenshot's dominant hue, in degrees.
    ///
    /// **Near-greys are weighted down**, because a screenshot is mostly window chrome and the grey
    /// is not the subject. Without that, almost every screenshot's "dominant colour" is the same
    /// pale grey and the choice below becomes meaningless.
    static func dominantHue(_ grid: Grid) -> Double? {
        var buckets = [Double](repeating: 0, count: 36)
        for cell in grid.cells {
            let maximum = max(cell.r, cell.g, cell.b)
            let minimum = min(cell.r, cell.g, cell.b)
            let chroma = maximum - minimum
            guard chroma > 0.08 else { continue }   // grey: ignored
            let hue = hueDegrees(cell)
            buckets[Int(hue / 10) % 36] += chroma
        }
        guard let best = buckets.indices.max(by: { buckets[$0] < buckets[$1] }),
              buckets[best] > 0 else { return nil }
        return Double(best) * 10 + 5
    }

    static func hueDegrees(_ cell: (r: Double, g: Double, b: Double)) -> Double {
        let maximum = max(cell.r, cell.g, cell.b)
        let minimum = min(cell.r, cell.g, cell.b)
        let chroma = maximum - minimum
        guard chroma > 0 else { return 0 }
        let hue: Double
        if maximum == cell.r { hue = 60 * ((cell.g - cell.b) / chroma).truncatingRemainder(dividingBy: 6) }
        else if maximum == cell.g { hue = 60 * (((cell.b - cell.r) / chroma) + 2) }
        else { hue = 60 * (((cell.r - cell.g) / chroma) + 4) }
        return hue < 0 ? hue + 360 : hue
    }

    static func meanLuma(_ grid: Grid) -> Double {
        guard !grid.cells.isEmpty else { return 0.5 }
        return grid.cells.reduce(0.0) { $0 + 0.2126 * $1.r + 0.7152 * $1.g + 0.0722 * $1.b }
            / Double(grid.cells.count)
    }

    /// Picks a background.
    ///
    /// Hue furthest from the screenshot's own, **then** filtered so a dark screenshot never lands
    /// on a dark background — the contrast floor matters more than the hue, because a dark app on
    /// a dark backdrop simply disappears into it.
    static func suggestedBackground(dominantHue: Double?,
                                    imageLuma: Double,
                                    catalogue: [BackgroundCatalogue.Entry]
                                        = BackgroundCatalogue.entries)
        -> BackgroundCatalogue.Entry? {
        guard !catalogue.isEmpty else { return nil }

        let wantsLight = imageLuma < 0.5
        let candidates = catalogue.filter {
            wantsLight ? $0.lightness >= 0.55 : $0.lightness <= 0.45
        }
        let pool = candidates.isEmpty ? catalogue : candidates

        guard let hue = dominantHue else {
            // No colour to contrast with: pick the most neutral of the pool.
            return pool.min { abs($0.lightness - (wantsLight ? 0.85 : 0.2))
                            < abs($1.lightness - (wantsLight ? 0.85 : 0.2)) }
        }
        return pool.max { circularDistance($0.hue, hue) < circularDistance($1.hue, hue) }
    }

    static func circularDistance(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(raw, 360 - raw)
    }

    /// Padding, in image pixels, adjusted per side by how much whitespace the shot already has.
    static func padding(contentBounds: CGRect, imageSize: CGSize) -> CGFloat {
        let base = min(max(0.08 * min(imageSize.width, imageSize.height), 24), 160)
        // A shot that is mostly margin already needs less added.
        let density = max(contentBounds.width * contentBounds.height, 0.05)
        return base * CGFloat(0.6 + 0.4 * min(density, 1))
    }
}
