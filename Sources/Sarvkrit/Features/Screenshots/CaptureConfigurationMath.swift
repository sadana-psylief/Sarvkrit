import CoreGraphics
import Foundation

/// The buffer size a capture should ask for.
///
/// Pure and separate from `SCKScreenCaptureService` so the arithmetic can be tested without a
/// display, and so there is one place that answers "how big should this buffer be".
///
/// **Size from `SCContentFilter.contentRect`, not from `SCWindow.frame`.**
/// `SCScreenshotManager.captureImage` always produces exactly the size the configuration asks
/// for — it does not fit the content to the buffer — so the requested size *is* the crop. The
/// filter's own `contentRect` is its statement of what it is going to render; a window's frame is
/// a second, independently-sourced value for the same thing, and the two are not contractually
/// equal. Deriving the size from the frame means the buffer and the content can disagree, and the
/// symptom is a silently clipped capture rather than an error.
///
/// **Measured on macOS 26 (Darwin 25.6), so the received wisdom here is narrower than it looks:**
/// for every window sampled — maximised and not, with `ignoreShadowsSingleWindow` both ways —
/// `contentRect` was exactly the window frame and did **not** expand to make room for a drop
/// shadow. `contentRect` is a property of the filter, which is built before the configuration
/// exists, so it cannot vary with the shadow flag. The frame-based sizing would therefore have
/// worked on this OS. It is still not what to write: it duplicates a value the filter already
/// owns, and the day the two diverge nothing fails loudly.
///
/// `naivePixelSize` exists only so the tests can assert the two answers differ when they are fed
/// differing inputs, rather than passing under either implementation.
enum CaptureConfigurationMath {

    /// Pixel dimensions for a capture, from the filter's own content rect.
    ///
    /// Rounded rather than truncated: a content rect of 100.5pt at 2x is 201 pixels, and
    /// truncating to 200 shaves a row off every capture on a fractional boundary.
    static func pixelSize(contentRect: CGRect, pointPixelScale: CGFloat) -> (width: Int, height: Int) {
        (
            width: max(1, Int((contentRect.width * pointPixelScale).rounded())),
            height: max(1, Int((contentRect.height * pointPixelScale).rounded()))
        )
    }

    /// What the naive version would have produced. Exists so the test can assert the two differ
    /// whenever a shadow is included, rather than passing under either implementation.
    static func naivePixelSize(windowFrame: CGRect,
                               pointPixelScale: CGFloat) -> (width: Int, height: Int) {
        (
            width: max(1, Int((windowFrame.width * pointPixelScale).rounded())),
            height: max(1, Int((windowFrame.height * pointPixelScale).rounded()))
        )
    }
}
