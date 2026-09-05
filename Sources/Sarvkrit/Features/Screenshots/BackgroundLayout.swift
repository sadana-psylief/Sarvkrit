import CoreGraphics
import Foundation

/// Where the screenshot sits inside its background, and how big the finished canvas is.
///
/// Pure and separate from the drawing so the arithmetic is testable, and because the ordering
/// matters: **the aspect target is met by adding padding, never by cropping the screenshot.**
/// Trimming pixels off a capture to reach 16:9 would silently remove content the user framed
/// deliberately.
enum BackgroundLayout {

    static func compute(imageSize: CGSize, style: CaptureBackground) -> (canvas: CGSize, imageRect: CGRect) {
        guard imageSize.width > 0, imageSize.height > 0 else { return (.zero, .zero) }

        let padded = CGSize(width: imageSize.width + style.padding * 2,
                            height: imageSize.height + style.padding * 2)

        var canvas = padded
        if let target = style.aspect.value(originalSize: imageSize), target > 0 {
            // Grow the shorter dimension until the ratio is met, which is what keeps the promise
            // above: the target is reached by adding canvas, never by taking pixels off the shot.
            if padded.width / padded.height < target {
                canvas.width = padded.height * target
            } else {
                canvas.height = padded.width / target
            }
        }

        return (canvas, place(imageSize: imageSize, in: canvas, style: style))
    }

    /// Where the screenshot goes inside a canvas that is already the right size.
    ///
    /// Two things move it. **Inset** shrinks it — uniformly, so the capture is never stretched —
    /// which is the opposite of padding: padding grows the canvas and leaves the shot alone.
    /// **Alignment** then spends whatever room is left over.
    ///
    /// **Alignment redistributes the padding; it does not spend leftovers.** The first version
    /// worked inside the canvas already inset by the padding, so it could only move the shot into
    /// slack that something else had created — and the only thing that creates slack is the Ratio
    /// target, which grows exactly one dimension. On `.original` with a landscape capture that is
    /// always the horizontal one, so vertical free space was zero on every screenshot anybody
    /// would ever take. The bug report was "alignment does not work only left center right no top
    /// or bottom", and it was accurate.
    ///
    /// So the free space now includes the padding, and a quarter of the padding stays behind as a
    /// margin on whichever side you align to:
    ///
    /// - **centre** lands on `F / 2`, which is exactly where it always was — nothing already made
    ///   moves;
    /// - **an edge** keeps `padding × 0.25` near and puts the other 175% opposite, so the total
    ///   padding is preserved and the shot is never flush. Flush matters: it would clip the
    ///   shadow against the canvas edge and generally reads as a mistake rather than a choice;
    /// - **padding 0** collapses the margin to nothing and alignment goes all the way, which is
    ///   right — there is no padding to preserve.
    private static func place(imageSize: CGSize, in canvas: CGSize,
                              style: CaptureBackground) -> CGRect {
        let inset = max(style.inset, 0)
        let scale = min(1, min((imageSize.width - inset * 2) / imageSize.width,
                               (imageSize.height - inset * 2) / imageSize.height))
        // A shot inset past its own size would invert; leave a sliver rather than a negative rect.
        let drawn = CGSize(width: max(imageSize.width * scale, 1),
                           height: max(imageSize.height * scale, 1))

        let padding = max(style.padding, 0)
        let free = CGSize(width: max(canvas.width - drawn.width, 0),
                          height: max(canvas.height - drawn.height, 0))
        let unit = style.alignment.unitPoint

        /// Where the image starts along one axis, given all the free space on it.
        ///
        /// The margin is halved into `free / 2` as well as clamped, so a canvas with less room
        /// than two margins centres rather than handing back a negative offset.
        func offset(free: CGFloat, unit: CGFloat) -> CGFloat {
            let margin = min(padding * 0.25, free / 2)
            return margin + (free - margin * 2) * unit
        }

        return CGRect(x: offset(free: free.width, unit: unit.x),
                      y: offset(free: free.height, unit: unit.y),
                      width: drawn.width, height: drawn.height)
    }
}
