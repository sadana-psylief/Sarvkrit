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

    /// An odd count so there is a middle pixel to point at, and about 5x so a single pixel is
    /// still identifiable without the loupe covering what you are aiming at.
    private static let magnifierTiles = 25
    private static let magnifierTileSize: CGFloat = 5.2

    /// Pointer position in view coordinates, for the crosshair.
    private var pointer: CGPoint?
    /// The handle currently being dragged on a settled selection.
    private var activeHandle: SelectionHandles.Handle?
    /// Where a press inside a settled selection started, and where that selection was — enough to
    /// drag it somewhere else. Absolute, so the rect tracks the pointer rather than drifting.
    private var movePress: (start: CGPoint, origin: CGPoint)?
    /// Whether that press has travelled far enough to be a move rather than the click that takes
    /// the shot. Without it, the hand's small wobble on a click would nudge the selection.
    private var isMovingSelection = false

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
        let local = convert(event.locationInWindow, from: nil)

        if let settled = gesture.settledRect {
            // A press on a handle adjusts the selection rather than starting a new one —
            // otherwise the only way to fix one that is slightly wrong is Escape and start the
            // whole capture again.
            if let handle = SelectionHandles.handle(at: local, bounds: viewRect(settled)) {
                activeHandle = handle
                needsDisplay = true
                return
            }
            // A press *inside* waits for the mouse-up that takes the shot. Falling through here
            // called `began` and threw the settled rect away, so clicking your own selection
            // silently cancelled it — which a synthesised drag caught and a hundred unit tests
            // on the gesture could not, because the bug was in the view's dispatch.
            if viewRect(settled).contains(local) {
                movePress = (start: local, origin: settled.origin)
                return
            }
            // A press outside starts again, which is what the hand expects.
        }

        gesture.began(at: globalPoint(local))
        applyModifiers(event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .area = mode else { return }
        let local = convert(event.locationInWindow, from: nil)
        pointer = local

        if let activeHandle {
            gesture.resize(handle: activeHandle, to: globalPoint(local),
                           constrainAspect: event.modifierFlags.contains(.shift))
            needsDisplay = true
            return
        }

        // Dragging the inside of a settled selection moves it. Before this, `moved` was a no-op
        // on a settled gesture, so the attempt did nothing and the mouse-up took the shot at the
        // old position — the selection appearing to refuse to be moved, and then firing anyway.
        if let movePress {
            let delta = CGSize(width: local.x - movePress.start.x,
                               height: local.y - movePress.start.y)
            guard isMovingSelection
                || max(abs(delta.width), abs(delta.height)) >= SelectionGesture.minimumDragDistance
            else { return }
            isMovingSelection = true
            gesture.move(originTo: CGPoint(x: movePress.origin.x + delta.width,
                                           y: movePress.origin.y + delta.height))
            needsDisplay = true
            return
        }

        applyModifiers(event)
        gesture.moved(to: globalPoint(local))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if activeHandle != nil {
            // Adjusting, not finishing: the capture is taken on Return or a click inside.
            activeHandle = nil
            needsDisplay = true
            return
        }

        if movePress != nil {
            let wasMoving = isMovingSelection
            movePress = nil
            isMovingSelection = false
            // Having moved it, the release is the end of the move — not also the click that takes
            // the shot. A press that never travelled falls through and confirms, as it should.
            if wasMoving {
                needsDisplay = true
                return
            }
        }

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

        if let settled = gesture.settledRect {
            // Clicking inside a settled selection takes it; clicking outside starts over. Both
            // are what the hand expects once handles exist.
            let local = convert(event.locationInWindow, from: nil)
            if viewRect(settled).contains(local) {
                delegate?.selectionView(self, didConfirm: settled)
            }
            needsDisplay = true
            return
        }

        if gesture.ended() != nil {
            // Settled rather than confirmed, so it can be adjusted by its handles. Return or a
            // click inside takes the shot.
            needsDisplay = true
            return
        }
        // A click with no drag dismisses. Anything else would leave the user stuck behind a
        // full-screen overlay wondering which key closes it.
        delegate?.selectionViewDidCancel(self)
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
            } else if let rect = gesture.settledRect ?? gesture.currentRect {
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

        // Dim everything outside the selection — but **only once there is one**.
        //
        // Darkening the whole screen the moment the overlay opens makes the thing you are trying
        // to aim at harder to see, which is backwards: the dim exists to show what you have
        // chosen, not to announce that a tool is open. The frozen screen at full brightness is
        // what you are picking from.
        if let selection {
            // One even-odd fill rather than four rectangles, which would leave hairline seams
            // where they meet.
            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(selection)
            context.addPath(path)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }

        if let selection {
            drawSelectionBorder(selection, in: context)
            if !isWindowMode, gesture.settledRect != nil {
                drawHandles(for: selection, in: context)
            }
            if showsDimensions { drawReadout(for: selection, in: context) }
        }

        // No crosshair or loupe in window mode: there is nothing to line up to the pixel, and a
        // loupe over a highlighted window is only clutter.
        if !isWindowMode, let pointer, selection == nil || gesture.isActive {
            if showsCrosshair { drawCrosshair(at: pointer, in: context, avoiding: selection) }
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

    /// The loupe, sampled straight out of the frozen bitmap.
    ///
    /// This is the payoff for freezing: a `cropping(to:)` on an image already held, drawn with
    /// interpolation off so individual pixels stay square instead of being smeared by the
    /// resampler.
    ///
    /// The centre row and column are **tinted rather than outlined**, with the centre pixel left
    /// clear. An accent ring around the middle cell — which is what this drew first — hides the
    /// one pixel you are trying to look at, which defeats the whole instrument.
    private func drawMagnifier(at point: CGPoint, in context: CGContext) {
        guard let frozenImage else { return }
        let global = globalPoint(point)
        guard let source = MagnifierSampler.sourceRect(
            around: global, tileCount: Self.magnifierTiles, in: display),
              let patch = frozenImage.cropping(to: source) else { return }

        let side = CGFloat(Self.magnifierTiles) * Self.magnifierTileSize
        // Below-right of the pointer, flipping near an edge so the loupe never hangs off the
        // screen — which is exactly where you need it.
        var origin = CGPoint(x: point.x + 22, y: point.y - side - 22)
        if origin.x + side > bounds.maxX { origin.x = point.x - side - 22 }
        if origin.y < bounds.minY { origin.y = point.y + 22 }
        let box = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let radius = side * 0.11

        context.saveGState()
        let clip = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)
        context.addPath(clip)
        context.clip()
        // The patch is in top-left pixel order and this view is bottom-left, so it goes in flipped.
        context.translateBy(x: 0, y: box.maxY + box.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(patch, in: box)
        context.restoreGState()

        let offset = MagnifierSampler.centreOffset(around: global, sourceRect: source, in: display)
        let tile = Self.magnifierTileSize
        let cell = CGRect(x: box.minX + offset.x * tile,
                          y: box.maxY - (offset.y + 1) * tile,
                          width: tile, height: tile)

        context.saveGState()
        context.addPath(clip)
        context.clip()
        // A full-width row and column at 45% black, then the centre cell painted back out. The
        // result is a crosshair that points at the pixel without covering it.
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.fill(CGRect(x: box.minX, y: cell.minY, width: side, height: tile))
        context.fill(CGRect(x: cell.minX, y: box.minY, width: tile, height: side))
        context.restoreGState()

        context.saveGState()
        context.addPath(clip)
        context.clip()
        context.translateBy(x: 0, y: box.maxY + box.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        // Redraw just the middle pixel, so it shows its true colour through the tinted cross.
        if let centre = patch.cropping(to: CGRect(x: offset.x, y: offset.y, width: 1, height: 1)) {
            context.draw(centre, in: CGRect(x: cell.minX,
                                            y: box.maxY + box.minY - cell.maxY,
                                            width: tile, height: tile))
        }
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(NSColor(white: 0.24, alpha: 1).cgColor)
        context.setLineWidth(2)
        context.addPath(clip)
        context.strokePath()
        context.restoreGState()

        drawPointerReadout(at: point, global: global, in: context)
    }

    /// The pointer's coordinates, in two lines beside the cursor.
    ///
    /// Light text with a dark outline rather than a filled pill: over a frozen screen a pill is
    /// another rectangle competing with the selection, while outlined text stays readable on
    /// anything without adding a shape.
    private func drawPointerReadout(at point: CGPoint, global: CGPoint,
                                    in context: CGContext) {
        let pixel = CGPoint(x: (global.x - display.frame.minX) * display.scale,
                            y: (display.frame.maxY - global.y) * display.scale)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{2009}"   // thin space, so 1200 reads as 1 200

        let lines = [formatter.string(from: NSNumber(value: Int(pixel.x))) ?? "",
                     formatter.string(from: NSNumber(value: Int(pixel.y))) ?? ""]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.75),
            .strokeWidth: -3.5,
        ]
        for (index, line) in lines.enumerated() {
            let string = NSAttributedString(string: line, attributes: attributes)
            string.draw(at: CGPoint(x: point.x + 12,
                                    y: point.y - 14 - CGFloat(index) * 13))
        }
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

    /// Grab points on a settled selection.
    ///
    /// Only once the drag is over. Drawing them *during* the drag would put eight small squares
    /// under the pointer at the exact moment the user is watching the edge they are dragging.
    private func drawHandles(for selection: CGRect, in context: CGContext) {
        context.saveGState()
        for rect in SelectionHandles.rects(for: selection).values {
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(1)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
        context.restoreGState()
    }

    /// Full-width guides through the pointer.
    ///
    /// Dark and thin. Bright white lines across a frozen screen read as part of the picture; a
    /// 40% black hairline reads as an instrument laid over it.
    private func drawCrosshair(at point: CGPoint, in context: CGContext,
                               avoiding selection: CGRect?) {
        context.saveGState()
        // Clipped out of the selection: guides are for finding an edge, and drawing them straight
        // across the region you have already chosen just adds two lines over your content.
        if let selection {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(selection)
            context.addPath(path)
            context.clip(using: .evenOdd)
        }
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
