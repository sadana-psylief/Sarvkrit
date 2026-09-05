import CoreGraphics

extension CGContext {
    /// Draws an image into a context whose CTM has been flipped to a **top-left origin**.
    ///
    /// **`CGContext.draw(_:in:)` always places an image bottom-up in the current coordinate
    /// system.** In a context that has been flipped so document coordinates read naturally — which
    /// is every context in this feature, and every `NSView` with `isFlipped == true` — that means
    /// the picture comes out upside down while everything drawn with explicit coordinates comes out
    /// the right way up. The result looks like the *screenshot* is broken rather than the drawing
    /// code, which is exactly how long it took to spot.
    ///
    /// Flipping locally around the destination rect keeps the fix at the one call that needs it,
    /// rather than making every caller reason about which way up the CTM currently is.
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: 0, y: rect.midY * 2)
        scaleBy(x: 1, y: -1)
        draw(image, in: rect)
        restoreGState()
    }
}

extension CGPath {
    /// A rounded rect whose corner radius cannot exceed what CoreGraphics accepts.
    ///
    /// **`CGPath(roundedRect:cornerWidth:cornerHeight:)` requires the corner to be at most half
    /// the side, and asserts when it is not.** Three places here build one from a radius that can
    /// come from a document or a slider, and each had to remember the cap independently —
    /// `drawText` did (its comment says "never an invalid path"), the rectangle annotation did
    /// not, and the background's corner radius only stayed inside the limit because its slider
    /// stopped at 64. That slider now goes to half the shorter side, which reaches the limit
    /// exactly, and the Inset slider shrinks the drawn rect *below* the size that maximum was
    /// computed from — so the background would have been over the line before the slider was even
    /// at fault.
    ///
    /// One helper, so the cap is not something three callers have to know about.
    static func rounded(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let radius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                      transform: nil)
    }
}
