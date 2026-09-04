import CoreGraphics
import Foundation

/// The one mapping between the editor's view space and the document's image space.
///
/// Everything in a document is in image pixels; everything the mouse reports is in view points.
/// Keeping the conversion in one tested place is the same defence `ScreenCoordinates` provides on
/// the capture side, and for the same reason: the failure mode is annotations landing near but
/// not on the thing they were drawn over, which reads as a rendering bug rather than a units one.
struct CanvasTransform: Equatable {
    let imageSize: CGSize
    /// View points per image pixel.
    let zoom: CGFloat
    /// Where the image's top-left sits in the view, in view points.
    let offset: CGPoint

    init(imageSize: CGSize, zoom: CGFloat = 1, offset: CGPoint = .zero) {
        self.imageSize = imageSize
        self.zoom = max(zoom, 0.0001)
        self.offset = offset
    }

    func toImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / zoom, y: (point.y - offset.y) / zoom)
    }

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + offset.x, y: point.y * zoom + offset.y)
    }

    func toImage(_ rect: CGRect) -> CGRect {
        CGRect(origin: toImage(rect.origin),
               size: CGSize(width: rect.width / zoom, height: rect.height / zoom))
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin),
               size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    /// A fixed on-screen grab distance, expressed in image pixels.
    ///
    /// Without this a 6pt handle is 6 image pixels — which at 4× zoom is a 24pt target and at
    /// 25% is a 1.5pt one. The physical size is what the user's hand cares about.
    func imageTolerance(forViewTolerance tolerance: CGFloat) -> CGFloat {
        tolerance / zoom
    }

    /// Fits the image inside a view, centred.
    static func fitting(imageSize: CGSize,
                        in viewSize: CGSize,
                        allowUpscale: Bool = false) -> CanvasTransform {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return CanvasTransform(imageSize: imageSize)
        }
        let raw = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let zoom = allowUpscale ? raw : min(raw, 1)
        return CanvasTransform(
            imageSize: imageSize,
            zoom: zoom,
            offset: CGPoint(x: (viewSize.width - imageSize.width * zoom) / 2,
                            y: (viewSize.height - imageSize.height * zoom) / 2))
    }
}
