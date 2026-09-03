import CoreGraphics
import Foundation

/// Where the screenshot sits inside its background, and how big the finished canvas is.
///
/// Pure and separate from the drawing so the arithmetic is testable, and because the ordering
/// matters: **the aspect target is met by adding padding, never by cropping the screenshot.**
/// Trimming pixels off a capture to reach 16:9 would silently remove content the user framed
/// deliberately.
enum BackgroundLayout {

    static func compute(imageSize: CGSize, style: BackgroundStyle) -> (canvas: CGSize, imageRect: CGRect) {
        guard imageSize.width > 0, imageSize.height > 0 else { return (.zero, .zero) }

        let padded = CGSize(width: imageSize.width + style.padding * 2,
                            height: imageSize.height + style.padding * 2)

        guard let target = style.aspect.value(originalSize: imageSize), target > 0 else {
            return (padded, CGRect(x: style.padding, y: style.padding,
                                   width: imageSize.width, height: imageSize.height))
        }

        // Grow the shorter dimension until the ratio is met. Symmetric, so the screenshot stays
        // centred rather than drifting to one side.
        var canvas = padded
        if padded.width / padded.height < target {
            canvas.width = padded.height * target
        } else {
            canvas.height = padded.width / target
        }

        return (canvas, CGRect(x: (canvas.width - imageSize.width) / 2,
                               y: (canvas.height - imageSize.height) / 2,
                               width: imageSize.width, height: imageSize.height))
    }
}
