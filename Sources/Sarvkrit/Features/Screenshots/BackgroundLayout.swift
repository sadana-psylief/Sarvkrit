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
    /// **Padding is not room to spend.** Alignment works inside the canvas *already inset by the
    /// padding*, so it can never push the screenshot into its own margin. Letting it do so was the
    /// first version of this, and it meant choosing "top left" silently threw the padding away —
    /// the two controls fought and the last one touched won.
    ///
    /// So the slack is only ever what an aspect target added or an inset freed. With neither, all
    /// nine alignments land in the same place, which is correct rather than a bug: there is
    /// nowhere else to go.
    private static func place(imageSize: CGSize, in canvas: CGSize,
                              style: CaptureBackground) -> CGRect {
        let inset = max(style.inset, 0)
        let scale = min(1, min((imageSize.width - inset * 2) / imageSize.width,
                               (imageSize.height - inset * 2) / imageSize.height))
        // A shot inset past its own size would invert; leave a sliver rather than a negative rect.
        let drawn = CGSize(width: max(imageSize.width * scale, 1),
                           height: max(imageSize.height * scale, 1))

        // The padding is guaranteed on all four sides, so a canvas smaller than twice the padding
        // still leaves the image centred rather than pushed off one edge.
        let padding = max(style.padding, 0)
        let content = CGRect(x: padding, y: padding,
                             width: max(canvas.width - padding * 2, 0),
                             height: max(canvas.height - padding * 2, 0))
        let free = CGSize(width: max(content.width - drawn.width, 0),
                          height: max(content.height - drawn.height, 0))
        let unit = style.alignment.unitPoint
        return CGRect(x: content.minX + free.width * unit.x,
                      y: content.minY + free.height * unit.y,
                      width: drawn.width, height: drawn.height)
    }
}
