import CoreGraphics
import Foundation

/// Which pixels the loupe shows.
///
/// Pure, because the interesting cases are all at the edges of the bitmap — a pointer in the
/// corner of a display has no pixels on two sides of it, and `CGImage.cropping(to:)` returns nil
/// for a rect that isn't wholly inside the image rather than clamping. Getting that wrong makes
/// the magnifier vanish exactly where you most need it: on the edge you are trying to line up.
enum MagnifierSampler {

    /// The pixel rect to crop for a loupe centred on `point`.
    ///
    /// - Parameters:
    ///   - point: pointer position in global AppKit points.
    ///   - tileCount: how many source pixels across the loupe shows. Odd, so there is a middle
    ///     pixel to report the colour of.
    /// - Returns: nil when the display has fewer pixels than the loupe wants, which is not a real
    ///   display but is a real test.
    static func sourceRect(around point: CGPoint,
                           tileCount: Int,
                           in display: DisplaySnapshotGeometry) -> CGRect? {
        let side = CGFloat(max(1, tileCount))
        guard display.pixelSize.width >= side, display.pixelSize.height >= side else { return nil }

        // Centre pixel, in the bitmap's own top-left space.
        let centre = CGPoint(
            x: (point.x - display.frame.minX) * display.scale,
            y: (display.frame.maxY - point.y) * display.scale)

        // Half the *tile count*, floored — not half the side length. For an odd loupe the pointer's
        // own pixel has to be the middle one, and `centre - side/2` puts it one off centre, which
        // shows as the crosshair sitting a pixel away from what the colour readout reports.
        let half = CGFloat(max(1, tileCount) / 2)
        var origin = CGPoint(x: centre.x.rounded(.down) - half,
                             y: centre.y.rounded(.down) - half)
        // Slide the whole window back inside rather than shrinking it: a loupe that changes size
        // near an edge is more disorienting than one that stops following the pointer exactly.
        origin.x = min(max(origin.x, 0), display.pixelSize.width - side)
        origin.y = min(max(origin.y, 0), display.pixelSize.height - side)

        return CGRect(x: origin.x, y: origin.y, width: side, height: side)
    }

    /// Where the centre pixel sits within the sampled rect, so the crosshair lands on the pixel
    /// the pointer is actually over even when the rect has been slid away from the edge.
    static func centreOffset(around point: CGPoint,
                             sourceRect: CGRect,
                             in display: DisplaySnapshotGeometry) -> CGPoint {
        let centre = CGPoint(
            x: (point.x - display.frame.minX) * display.scale,
            y: (display.frame.maxY - point.y) * display.scale)
        return CGPoint(x: (centre.x - sourceRect.minX).rounded(.down),
                       y: (centre.y - sourceRect.minY).rounded(.down))
    }
}
