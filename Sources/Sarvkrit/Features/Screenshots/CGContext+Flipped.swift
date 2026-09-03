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
