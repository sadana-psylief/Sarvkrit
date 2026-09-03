import AppKit
import CoreGraphics

@MainActor
protocol SelectionViewDelegate: AnyObject {
    func selectionView(_ view: SelectionView, didConfirm rect: CGRect)
    func selectionViewDidCancel(_ view: SelectionView)
}

/// The frozen screen, the dimming, and the selection being drawn on top of it.
///
/// **AppKit rather than SwiftUI, deliberately.** This redraws on every mouse-moved event over a
/// bitmap that is 3024×1964 on this machine and larger on a 5K display. SwiftUI would re-evaluate
/// a view tree per frame where this dirties a rect, and the magnifier needs to sample the
/// `CGImage` directly rather than through an `Image`. It is the same "drop to AppKit and say why"
/// move `ShelfDragSource` and `ShortcutRecorderView` already make.
///
/// The frozen bitmap is the view's backing layer contents, so scrolling it around costs nothing —
/// only the selection chrome is ever redrawn.
final class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?

    private var gesture: SelectionGesture
    private let frozenImage: CGImage?
    private let display: DisplaySnapshotGeometry

    var showsCrosshair = true
    var showsDimensions = true

    /// Pointer position in view coordinates, for the crosshair.
    private var pointer: CGPoint?

    init(display: DisplaySnapshotGeometry, frozenImage: CGImage?) {
        self.display = display
        self.frozenImage = frozenImage
        self.gesture = SelectionGesture(display: display)
        super.init(frame: NSRect(origin: .zero, size: display.frame.size))
        wantsLayer = true
        // The bitmap as layer contents: a straight blit the compositor handles, rather than an
        // NSImageView that would resample it on every layout pass.
        layer?.contents = frozenImage
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var acceptsFirstResponder: Bool { true }
    /// Or the first click merely focuses the panel and the drag it belongs to is lost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Coordinates

    /// View points → global AppKit points. The view fills its display exactly, so this is a
    /// translation by the display's origin — which is negative for a display left of the primary.
    private func globalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + display.frame.minX, y: point.y + display.frame.minY)
    }

    private func viewRect(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        gesture.began(at: globalPoint(convert(event.locationInWindow, from: nil)))
        applyModifiers(event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        applyModifiers(event)
        gesture.moved(to: globalPoint(local))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        applyModifiers(event)
        if let rect = gesture.ended() {
            delegate?.selectionView(self, didConfirm: rect)
        } else {
            // A click with no drag dismisses. Anything else would leave the user stuck behind a
            // full-screen overlay wondering which key closes it.
            delegate?.selectionViewDidCancel(self)
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    private func applyModifiers(_ event: NSEvent) {
        // Shift locks to whatever ratio the selection already has, so it holds the shape you were
        // already drawing rather than snapping to a square.
        if event.modifierFlags.contains(.shift) {
            if gesture.aspectRatio == nil, let rect = gesture.currentRect, rect.height > 0 {
                gesture.aspectRatio = rect.width / rect.height
            }
        } else {
            gesture.aspectRatio = nil
        }
        gesture.resizesFromCenter = event.modifierFlags.contains(.option)
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:    // Escape
            gesture.cancel()
            delegate?.selectionViewDidCancel(self)
        case 36:    // Return
            if let rect = gesture.currentRect {
                delegate?.selectionView(self, didConfirm: rect)
            }
        case 123, 124, 125, 126:    // arrows
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGSize
            switch Int(event.keyCode) {
            case 123: delta = CGSize(width: -step, height: 0)
            case 124: delta = CGSize(width: step, height: 0)
            case 125: delta = CGSize(width: 0, height: -step)
            default:  delta = CGSize(width: 0, height: step)
            }
            gesture.nudge(by: delta)
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let selection = gesture.currentRect.map(viewRect)

        // Dim everything outside the selection. Drawn as the whole bounds minus the selection
        // using the even-odd rule, so there is one fill rather than four rectangles that leave
        // hairline seams at their joins.
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        if let selection {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(selection)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }
        context.restoreGState()

        if let selection {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1)
            // Inset by half a line width so the 1pt stroke lands on the pixel boundary instead of
            // straddling it and rendering as a soft 2px line.
            context.stroke(selection.insetBy(dx: 0.5, dy: 0.5))
            if showsDimensions { drawReadout(for: selection, in: context) }
        } else if showsCrosshair, let pointer {
            drawCrosshair(at: pointer, in: context)
        }
    }

    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: point.y + 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y + 0.5))
        context.move(to: CGPoint(x: point.x + 0.5, y: 0))
        context.addLine(to: CGPoint(x: point.x + 0.5, y: bounds.maxY))
        context.strokePath()
        context.restoreGState()
    }

    private func drawReadout(for selection: CGRect, in context: CGContext) {
        guard let size = gesture.pixelSize else { return }
        let text = "\(Int(size.width)) × \(Int(size.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let padding: CGFloat = 6
        let boxSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + 4)

        // Above the selection, unless that would put it off the top of the screen — in which case
        // inside it, which is the only place always available.
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + boxSize.height > bounds.maxY { origin.y = selection.maxY - boxSize.height - 6 }
        origin.x = min(max(origin.x, 0), bounds.maxX - boxSize.width)

        let box = CGRect(origin: origin, size: boxSize)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        context.restoreGState()

        string.draw(at: CGPoint(x: box.minX + padding, y: box.minY + 2))
    }
}
