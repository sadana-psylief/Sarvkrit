import CoreGraphics
import Foundation

/// One display, frozen at the instant of capture.
///
/// Carried by value so nothing downstream re-asks `NSScreen` — by the time a crop happens the
/// user may have unplugged a monitor, and a selection drawn against one arrangement must not be
/// cropped against another.
///
/// **`scale` always comes from `SCContentFilter.pointPixelScale`, never `NSScreen.backingScaleFactor`.**
/// The two agree for ordinary displays and disagree exactly when one is running a scaled
/// (non-native) resolution — and it is ScreenCaptureKit that decides how big the buffer is, so its
/// answer is the only one that describes the bitmap we actually got.
struct DisplaySnapshotGeometry: Equatable {
    let displayID: CGDirectDisplayID
    /// Global AppKit points, bottom-left origin. May be negative: a display to the left of, or
    /// below, the primary has a negative origin and that is not an error state.
    let frame: CGRect
    let scale: CGFloat
    /// The bitmap's true pixel dimensions.
    let pixelSize: CGSize
}

/// Converting between a selection on screen and a crop out of a captured bitmap.
///
/// **This is not the same flip as `ScreenCoordinates`, and confusing the two is the bug this file
/// exists to prevent.** `ScreenCoordinates` converts between Cocoa and Accessibility, which are
/// both *global* spaces, so it flips against the **primary** display's height. Cropping a
/// per-display bitmap flips against **that display's own `maxY`**, because each display's bitmap
/// has its own top-left origin. Using `primaryHeight` here is the mirror image of the sub-bug
/// `ScreenCoordinates` documents, and like that one it is correct-by-accident on a single-display
/// Mac — which is why every case below is tested against synthetic arrangements instead.
///
/// The arithmetic, written out because this is where the sign errors live:
/// ```
/// x_px = (rect.minX - display.frame.minX) * scale
/// y_px = (display.frame.maxY - rect.maxY) * scale
/// ```
enum CaptureGeometry {

    /// A rect in global AppKit points → the pixel rect to crop from that display's bitmap.
    static func pixelRect(forGlobalRect rect: CGRect, in display: DisplaySnapshotGeometry) -> CGRect {
        CGRect(
            x: (rect.minX - display.frame.minX) * display.scale,
            y: (display.frame.maxY - rect.maxY) * display.scale,
            width: rect.width * display.scale,
            height: rect.height * display.scale
        )
    }

    /// The inverse, for putting a pinned window back where its capture came from.
    static func globalRect(forPixelRect rect: CGRect, in display: DisplaySnapshotGeometry) -> CGRect {
        guard display.scale > 0 else { return .zero }
        let width = rect.width / display.scale
        let height = rect.height / display.scale
        return CGRect(
            x: display.frame.minX + rect.minX / display.scale,
            y: display.frame.maxY - rect.maxY / display.scale,
            width: width,
            height: height
        )
    }

    /// Which display a point is on.
    ///
    /// Returns nil rather than falling back to a default: a pointer that is on no display means
    /// something has gone wrong, and cropping the *wrong* screen is worse than declining.
    static func display(containing point: CGPoint,
                        in displays: [DisplaySnapshotGeometry]) -> DisplaySnapshotGeometry? {
        displays.first { $0.frame.contains(point) }
    }

    /// Keeps a selection inside the display it started on.
    static func clamp(_ rect: CGRect, to display: DisplaySnapshotGeometry) -> CGRect {
        rect.intersection(display.frame)
    }

    /// The rect between two drag points.
    ///
    /// Normalised, so dragging up-left gives the same answer as dragging down-right — otherwise a
    /// backwards drag produces a negative width and every downstream calculation quietly inverts.
    ///
    /// - Parameter aspectRatio: width ÷ height to lock to, or nil for free. The locked rect keeps
    ///   the anchor corner fixed and takes the **larger** of the two candidate sizes, so the
    ///   selection tracks the pointer rather than lagging behind it.
    /// - Parameter fromCenter: grow around `anchor` instead of away from it (the ⌥ modifier).
    static func selectionRect(from anchor: CGPoint, to current: CGPoint,
                              aspectRatio: CGFloat?, fromCenter: Bool) -> CGRect {
        var dx = current.x - anchor.x
        var dy = current.y - anchor.y

        if let ratio = aspectRatio, ratio > 0 {
            let byWidth = abs(dx)
            let byHeight = abs(dy) * ratio
            let width = max(byWidth, byHeight)
            let height = width / ratio
            dx = dx < 0 ? -width : width
            dy = dy < 0 ? -height : height
        }

        if fromCenter {
            return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy),
                          width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy),
                      width: abs(dx), height: abs(dy))
    }

    /// Nudges a rect onto whole pixels for the display it sits on.
    ///
    /// **A half-pixel crop is a blurry screenshot**, and it is the symptom nobody attributes to
    /// rounding — the image looks soft and you blame the display or the encoder. At 2× a 0.25pt
    /// origin is half a pixel, which is easy to land on with a trackpad.
    static func snapToPixelGrid(_ rect: CGRect, in display: DisplaySnapshotGeometry) -> CGRect {
        let pixels = pixelRect(forGlobalRect: rect, in: display).integral
        return globalRect(forPixelRect: pixels, in: display)
    }

    /// What the dimension readout shows. Pixels, not points — that is what the file will contain.
    static func pixelSize(of rect: CGRect, in display: DisplaySnapshotGeometry) -> CGSize {
        CGSize(width: (rect.width * display.scale).rounded(),
               height: (rect.height * display.scale).rounded())
    }

    /// A rect of an exact pixel size, centred on a point — the typed-size entry in All-In-One.
    static func rect(withPixelSize size: CGSize, centeredOn point: CGPoint,
                     in display: DisplaySnapshotGeometry) -> CGRect {
        guard display.scale > 0 else { return .zero }
        let width = size.width / display.scale
        let height = size.height / display.scale
        return CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }
}
