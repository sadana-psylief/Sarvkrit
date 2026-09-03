import CoreGraphics
import Foundation

/// Turning recognised text fragments into text a person can paste.
///
/// **This is where OCR quality actually lives.** Vision returns observations in no useful order,
/// and a naive top-to-bottom sort turns any two-column screenshot — a settings pane, a diff, a
/// spreadsheet — into interleaved nonsense. The recognition is Apple's; the ordering is ours, and
/// it is the part that decides whether the paste is usable.
///
/// Everything here is pure over rectangles, so the whole thing is tested without Vision.
enum ReadingOrder {

    struct Fragment: Equatable {
        let text: String
        /// **Top-left origin, y increasing downward.** Vision reports normalised boxes with a
        /// *bottom-left* origin — the opposite of the rest of this feature — so the conversion
        /// happens at the boundary, in `TextRecognizer`, and never again after that.
        let rect: CGRect
    }

    /// Fragments grouped into lines, in reading order.
    static func lines(from fragments: [Fragment]) -> [[Fragment]] {
        guard !fragments.isEmpty else { return [] }

        let columns = columnGroups(fragments)
        var result: [[Fragment]] = []
        for column in columns {
            let sorted = column.sorted { $0.rect.midY < $1.rect.midY }
            var current: [Fragment] = []
            var runningMidY: CGFloat = 0
            var runningHeight: CGFloat = 0

            for fragment in sorted {
                if current.isEmpty {
                    current = [fragment]
                    runningMidY = fragment.rect.midY
                    runningHeight = fragment.rect.height
                    continue
                }
                // Half the running mean height: tolerant of a wobbly baseline and of one bold word
                // being a point taller, without merging two genuinely separate lines.
                if abs(fragment.rect.midY - runningMidY) <= runningHeight * 0.5 {
                    current.append(fragment)
                    runningMidY = (runningMidY * CGFloat(current.count - 1) + fragment.rect.midY)
                        / CGFloat(current.count)
                    runningHeight = (runningHeight * CGFloat(current.count - 1)
                                     + fragment.rect.height) / CGFloat(current.count)
                } else {
                    result.append(current.sorted { $0.rect.minX < $1.rect.minX })
                    current = [fragment]
                    runningMidY = fragment.rect.midY
                    runningHeight = fragment.rect.height
                }
            }
            if !current.isEmpty {
                result.append(current.sorted { $0.rect.minX < $1.rect.minX })
            }
        }
        return result
    }

    /// Splits fragments into columns by clustering their horizontal extents.
    ///
    /// Emitting column-by-column is the difference between a readable paste and interleaved
    /// nonsense on any two-column layout. A single column is the overwhelmingly common case and
    /// falls straight through.
    static func columnGroups(_ fragments: [Fragment]) -> [[Fragment]] {
        guard fragments.count > 1 else { return [fragments] }

        let sorted = fragments.sorted { $0.rect.minX < $1.rect.minX }
        let medianWidth = sorted.map(\.rect.width).sorted()[sorted.count / 2]
        // A gap wider than a typical fragment means the two sides don't belong to one flow.
        let gapThreshold = max(medianWidth * 0.5, 0.02)

        var groups: [[Fragment]] = []
        var current: [Fragment] = [sorted[0]]
        var currentMaxX = sorted[0].rect.maxX

        for fragment in sorted.dropFirst() {
            if fragment.rect.minX - currentMaxX > gapThreshold {
                groups.append(current)
                current = [fragment]
                currentMaxX = fragment.rect.maxX
            } else {
                current.append(fragment)
                currentMaxX = max(currentMaxX, fragment.rect.maxX)
            }
        }
        groups.append(current)

        // A "column" of one stray fragment is usually a caption or a badge, not a column. Folding
        // those back in avoids shredding an ordinary paragraph that happens to have a wide gap.
        guard groups.count > 1, groups.allSatisfy({ $0.count > 1 }) else { return [fragments] }
        return groups
    }

    /// The finished text.
    ///
    /// A vertical gap larger than 1.5× the median line height becomes a blank line, so paragraphs
    /// survive the trip.
    static func text(from fragments: [Fragment]) -> String {
        let grouped = lines(from: fragments)
        guard !grouped.isEmpty else { return "" }

        let heights = grouped.compactMap { $0.first?.rect.height }.sorted()
        let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]

        var output: [String] = []
        var previousBottom: CGFloat?
        for line in grouped {
            let joined = line.map(\.text).joined(separator: " ")
            if let previousBottom, let top = line.map(\.rect.minY).min(),
               medianHeight > 0, top - previousBottom > medianHeight * 1.5 {
                output.append("")
            }
            output.append(joined)
            previousBottom = line.map(\.rect.maxY).max()
        }
        return output.joined(separator: "\n")
    }
}
