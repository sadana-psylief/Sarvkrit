import AppKit
import CoreGraphics

@MainActor
protocol SelectionViewDelegate: AnyObject {
    func selectionView(_ view: SelectionView, didConfirm rect: CGRect)
    func selectionView(_ view: SelectionView, didConfirmWindow window: CapturableWindow)
    func selectionViewDidCancel(_ view: SelectionView)
}

/// What the overlay is asking the user to pick.
enum SelectionMode: Equatable {
    case area
    /// Hover to highlight, click to take. No dragging.
    case window([CapturableWindow])
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
    /// Disabled when the overlay is live rather than frozen: sampling a fresh capture per frame
    /// gives a loupe that stutters, which is worse than not having one. The settings row says so.
    var showsMagnifier = true

    private static let magnifierTiles = 15
    private static let magnifierTileSize: CGFloat = 8

    /// Pointer position in view coordinates, for the crosshair.
    private var pointer: CGPoint?

    private let mode: SelectionMode
    private var hoveredWindow: CapturableWindow?

    init(display: DisplaySnapshotGeometry, frozenImage: CGImage?, mode: SelectionMode = .area) {
        self.display = display
        self.frozenImage = frozenImage
        self.mode = mode
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

    /// Belt and braces alongside the window's `acceptsMouseMovedEvents`: a tracking area also
    /// tells us when the pointer leaves, so the crosshair doesn't stay frozen at the last place it
    /// was seen when the pointer crosses onto another display.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    /// Places the pointer before any event has arrived, so the overlay opens already showing the
    /// crosshair rather than looking inert until the hand moves.
    func seedPointer(_ globalPoint: CGPoint) {
        guard display.frame.contains(globalPoint) else { return }
        pointer = CGPoint(x: globalPoint.x - display.frame.minX,
                          y: globalPoint.y - display.frame.minY)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

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
        guard case .area = mode else { return }
        gesture.began(at: globalPoint(convert(event.locationInWindow, from: nil)))
        applyModifiers(event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .area = mode else { return }
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        applyModifiers(event)
        gesture.moved(to: globalPoint(local))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .window = mode {
            if let hoveredWindow {
                delegate?.selectionView(self, didConfirmWindow: hoveredWindow)
            } else {
                // Clicking where there is no window dismisses, rather than leaving the user stuck
                // behind a full-screen overlay with nothing highlighted.
                delegate?.selectionViewDidCancel(self)
            }
            return
        }
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
        let local = convert(event.locationInWindow, from: nil)
        pointer = local
        if case .window(let windows) = mode {
            hoveredWindow = WindowPicker.window(at: globalPoint(local), in: windows)
        }
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
            if case .window = mode {
                if let hoveredWindow { delegate?.selectionView(self, didConfirmWindow: hoveredWindow) }
            } else if let rect = gesture.currentRect {
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
        let selection: CGRect?
        if case .window = mode {
            selection = hoveredWindow.map { viewRect($0.frame) }
        } else {
            selection = gesture.currentRect.map(viewRect)
        }

        // Dim everything outside the selection. One even-odd fill rather than four rectangles,
        // which would leave hairline seams where they meet.
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
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
            drawSelectionBorder(selection, in: context)
            if showsDimensions { drawReadout(for: selection, in: context) }
        }

        // No crosshair or loupe in window mode: there is nothing to line up to the pixel, and a
        // loupe over a highlighted window is only clutter.
        if !isWindowMode, let pointer, selection == nil || gesture.isActive {
            if showsCrosshair { drawCrosshair(at: pointer, in: context) }
            if showsMagnifier { drawMagnifier(at: pointer, in: context) }
        }
    }

    /// A white line with a dark one just outside it.
    ///
    /// **Two lines, not one.** A single white border vanishes against pale content and a single
    /// dark one vanishes against dark content; the pair stays legible over anything, which is the
    /// whole problem when the backdrop is the user's own screen.
    private func drawSelectionBorder(_ selection: CGRect, in context: CGContext) {
        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        context.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(selection.insetBy(dx: 0.5, dy: 0.5))

        if isWindowMode {
            // A window is a target rather than something being drawn, so it also gets a tint.
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor)
            context.fill(selection)
        }
        context.restoreGState()
    }

    private func drawMagnifier(at point: CGPoint, in context: CGContext) {
        guard let frozenImage else { return }
        let global = globalPoint(point)
        guard let source = MagnifierSampler.sourceRect(
            around: global, tileCount: Self.magnifierTiles, in: display),
              let patch = frozenImage.cropping(to: source) else { return }

        let side = CGFloat(Self.magnifierTiles) * Self.magnifierTileSize
        // Below-right of the pointer, flipping to the other side near an edge so the loupe never
        // hangs off the screen — which is exactly where you need it.
        var origin = CGPoint(x: point.x + 16, y: point.y - side - 16)
        if origin.x + side > bounds.maxX { origin.x = point.x - side - 16 }
        if origin.y < bounds.minY { origin.y = point.y + 16 }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))

        context.saveGState()
        let clip = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(clip)
        context.clip()
        // The patch is in top-left pixel order and this view is bottom-left, so it goes in flipped.
        context.translateBy(x: 0, y: box.maxY + box.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(patch, in: box)
        context.restoreGState()

        context.saveGState()
        // Crosshair on the centre pixel, positioned from the sampler so it stays on the pointer's
        // own pixel even when the sample window slid away from a screen edge.
        let offset = MagnifierSampler.centreOffset(around: global, sourceRect: source, in: display)
        let cell = CGRect(
            x: box.minX + offset.x * Self.magnifierTileSize,
            y: box.maxY - (offset.y + 1) * Self.magnifierTileSize,
            width: Self.magnifierTileSize, height: Self.magnifierTileSize)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.stroke(cell.insetBy(dx: 0.5, dy: 0.5))

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.addPath(clip)
        context.strokePath()
        context.restoreGState()
    }

    private var isWindowMode: Bool {
        if case .window = mode { return true }
        return false
    }

    /// In window mode the readout describes the window under the pointer, which has its own size
    /// rather than one the gesture knows about.
    private func readoutPixelSize(for selection: CGRect) -> CGSize? {
        if isWindowMode {
            return CGSize(width: (selection.width * display.scale).rounded(),
                          height: (selection.height * display.scale).rounded())
        }
        return gesture.pixelSize
    }

    /// Full-width guides through the pointer.
    ///
    /// Dark and thin. Bright white lines across a frozen screen read as part of the picture; a
    /// 40% black hairline reads as an instrument laid over it.
    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: point.y + 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y + 0.5))
        context.move(to: CGPoint(x: point.x + 0.5, y: 0))
        context.addLine(to: CGPoint(x: point.x + 0.5, y: bounds.maxY))
        context.strokePath()
        context.restoreGState()
    }

    /// "1920 × 1080", in a pill anchored to the selection.
    private func drawReadout(for selection: CGRect, in context: CGContext) {
        guard let size = readoutPixelSize(for: selection) else { return }
        let string = NSAttributedString(string: DimensionReadout.text(for: size), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white,
        ])
        let textSize = string.size()
        let box = CGSize(width: textSize.width + 16, height: 22)

        // Below the selection and right-aligned to it, flipping above when there is no room —
        // near the bottom of the screen is exactly where a fixed position puts it off-screen.
        var origin = CGPoint(x: selection.maxX - box.width, y: selection.minY - box.height - 8)
        if origin.y < bounds.minY + 4 { origin.y = selection.maxY + 8 }
        if origin.y + box.height > bounds.maxY { origin.y = selection.minY + 8 }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - box.width - 8)

        let rect = CGRect(origin: origin, size: box)
        context.saveGState()
        context.setFillColor(NSColor(white: 0.153, alpha: 0.9).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 11, cornerHeight: 11,
                               transform: nil))
        context.fillPath()
        context.restoreGState()

        string.draw(at: CGPoint(x: rect.minX + 8, y: rect.midY - textSize.height / 2))
    }

}
