import CoreGraphics
import Foundation

/// Arranging several captures into one image.
enum CombineLayout {

    enum Mode: Equatable {
        case vertical
        case horizontal
        case grid(columns: Int)
    }

    /// How mismatched sizes are reconciled before laying out.
    enum Normalize: String, Codable, CaseIterable, Equatable {
        case none
        /// Scale everything up to the widest (or tallest).
        case widest
        /// Scale everything down to the narrowest.
        case narrowest

        var title: String {
            switch self {
            case .none: return "Leave as they are"
            case .widest: return "Match the largest"
            case .narrowest: return "Match the smallest"
            }
        }
    }

    /// Where each image goes, and how big the canvas is.
    ///
    /// **Spacing is between images only.** The outer margin belongs to the Background tool's
    /// padding, and having both would double it — a gap the user set once and sees twice.
    static func compute(sizes: [CGSize], mode: Mode, spacing: CGFloat,
                        normalize: Normalize) -> (canvas: CGSize, frames: [CGRect]) {
        guard !sizes.isEmpty else { return (.zero, []) }
        guard sizes.count > 1 else {
            return (sizes[0], [CGRect(origin: .zero, size: sizes[0])])
        }

        let scaled = normalised(sizes, mode: mode, normalize: normalize)

        switch mode {
        case .vertical:
            var y: CGFloat = 0
            var frames: [CGRect] = []
            for size in scaled {
                frames.append(CGRect(x: 0, y: y, width: size.width, height: size.height))
                y += size.height + spacing
            }
            let width = scaled.map(\.width).max() ?? 0
            // Centre anything narrower, so a mixed set doesn't read as left-aligned by accident.
            frames = zip(frames, scaled).map { frame, size in
                CGRect(x: (width - size.width) / 2, y: frame.minY,
                       width: size.width, height: size.height)
            }
            return (CGSize(width: width, height: max(0, y - spacing)), frames)

        case .horizontal:
            var x: CGFloat = 0
            var frames: [CGRect] = []
            for size in scaled {
                frames.append(CGRect(x: x, y: 0, width: size.width, height: size.height))
                x += size.width + spacing
            }
            let height = scaled.map(\.height).max() ?? 0
            frames = zip(frames, scaled).map { frame, size in
                CGRect(x: frame.minX, y: (height - size.height) / 2,
                       width: size.width, height: size.height)
            }
            return (CGSize(width: max(0, x - spacing), height: height), frames)

        case .grid(let requested):
            let columns = max(1, requested)
            let cellWidth = scaled.map(\.width).max() ?? 0
            let cellHeight = scaled.map(\.height).max() ?? 0
            let rows = Int((Double(scaled.count) / Double(columns)).rounded(.up))

            var frames: [CGRect] = []
            for (index, size) in scaled.enumerated() {
                let column = index % columns, row = index / columns
                let cellX = CGFloat(column) * (cellWidth + spacing)
                let cellY = CGFloat(row) * (cellHeight + spacing)
                frames.append(CGRect(x: cellX + (cellWidth - size.width) / 2,
                                     y: cellY + (cellHeight - size.height) / 2,
                                     width: size.width, height: size.height))
            }
            return (CGSize(width: CGFloat(columns) * cellWidth + CGFloat(columns - 1) * spacing,
                           height: CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing),
                    frames)
        }
    }

    private static func normalised(_ sizes: [CGSize], mode: Mode,
                                   normalize: Normalize) -> [CGSize] {
        guard normalize != .none else { return sizes }
        // Vertical stacks match on width; horizontal ones on height. A grid matches on width too,
        // since that is what makes the columns line up.
        let matchesWidth = mode != .horizontal
        let measures = sizes.map { matchesWidth ? $0.width : $0.height }
        guard let target = normalize == .widest ? measures.max() : measures.min(),
              target > 0 else { return sizes }

        return sizes.map { size in
            let current = matchesWidth ? size.width : size.height
            guard current > 0 else { return size }
            let scale = target / current
            return CGSize(width: size.width * scale, height: size.height * scale)
        }
    }
}
