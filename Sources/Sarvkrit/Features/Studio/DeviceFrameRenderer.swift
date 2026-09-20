import CoreGraphics
import Foundation

/// Drawing the bezel around the recording.
///
/// The screen is inset *inside* the frame rather than the frame being drawn around the screen, so
/// turning a device frame on does not change how much of the recording is visible — only how much
/// canvas the whole assembly occupies.
enum DeviceFrameRenderer {

    /// Where the recording goes once a frame is worn, and the paths to draw around it.
    struct Layout {
        let outer: CGPath
        let screen: CGPath
        let screenRect: CGRect
        let bezel: RGBAColour
        let rim: RGBAColour
    }

    /// - Parameter imageRect: where the recording would sit with no frame.
    static func layout(_ selection: DeviceFrameSelection, imageRect: CGRect) -> Layout? {
        guard let (frame, colourway) = selection.resolved() else { return nil }

        let shorter = min(imageRect.width, imageRect.height)
        let bezel = shorter * CGFloat(frame.bezelFraction)
        let screenRect = imageRect.insetBy(dx: bezel, dy: bezel)
        guard screenRect.width > 1, screenRect.height > 1 else { return nil }

        return Layout(
            outer: CGPath.rounded(imageRect,
                                  cornerRadius: shorter * CGFloat(frame.outerCornerFraction)),
            screen: CGPath.rounded(screenRect,
                                   cornerRadius: shorter * CGFloat(frame.screenCornerFraction)),
            screenRect: screenRect,
            bezel: colourway.body,
            rim: colourway.rim)
    }

    /// The body, drawn before the recording.
    static func drawBody(_ layout: Layout, in context: CGContext) {
        context.saveGState()
        context.addPath(layout.outer)
        context.setFillColor(layout.bezel.cgColor)
        context.fillPath()
        context.restoreGState()
    }

    /// The rim, drawn after — a hairline highlight along the bezel's inner edge.
    ///
    /// **This one line is what stops the frame reading as a border.** A flat rounded rectangle
    /// around a video looks like a mistake; a lit inner edge looks like glass in a case.
    static func drawRim(_ layout: Layout, in context: CGContext) {
        context.saveGState()
        context.addPath(layout.screen)
        context.setStrokeColor(layout.rim.cgColor)
        context.setLineWidth(max(1, layout.screenRect.width * 0.0018))
        context.strokePath()
        context.restoreGState()
    }
}
