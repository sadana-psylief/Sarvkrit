import AppKit
import CoreGraphics

/// The editing surface.
///
/// **AppKit with `draw(_:)`, not SwiftUI `Canvas`**, for three reasons that all bite at once:
/// `Canvas` redraws its whole content on every pass, which is the 60fps-over-a-5K-bitmap case that
/// must not regress; it is not a first responder, so it cannot receive the single-key tool
/// shortcuts; and it cannot host a text caret, so a text tool would need an `NSTextView` overlaid
/// on it anyway. Once an `NSView` is needed for input, it may as well own the drawing.
///
/// `isFlipped` is true so view space shares the document's top-left origin and `CanvasTransform`
/// is a scale plus a translate with no sign flip anywhere.
@MainActor
protocol AnnotationCanvasDelegate: AnyObject {
    func canvasDidEdit(_ view: AnnotationCanvasView)
    func canvas(_ view: AnnotationCanvasView, beginTextEditingAt point: CGPoint)
}

final class AnnotationCanvasView: NSView {
    weak var delegate: AnnotationCanvasDelegate?

    private let model: EditorDocumentModel
    private var transform: CanvasTransform

    /// The element being drawn right now, before it is committed.
    private var draft: AnnotationElement.Kind?
    private var dragStart: CGPoint?
    private var pencilPoints: [CGPoint] = []
    private var activeHandle: SelectionHandles.Handle?
    private var moveOrigin: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(model: EditorDocumentModel) {
        self.model = model
        self.transform = CanvasTransform(imageSize: model.document.imageSize)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    // MARK: - Layout

    override func layout() {
        super.layout()
        transform = CanvasTransform.fitting(imageSize: model.document.imageSize,
                                            in: bounds.size)
        needsDisplay = true
    }

    func refresh() { needsDisplay = true }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        transform.toImage(convert(event.locationInWindow, from: nil))
    }

    private var tolerance: CGFloat { transform.imageTolerance(forViewTolerance: 6) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        context.translateBy(x: transform.offset.x, y: transform.offset.y)
        context.scaleBy(x: transform.zoom, y: transform.zoom)

        var shown = model.document
        // The in-progress mark is drawn but never stored, so an abandoned drag leaves nothing.
        if let draft { shown.elements.append(AnnotationElement(z: .max, kind: draft)) }
        AnnotationRenderer.draw(shown, base: model.base, in: context,
                                filterCache: model.filterCache, quality: .interactive)
        context.restoreGState()

        if let selection = model.selection,
           let element = model.document.elements.first(where: { $0.id == selection }) {
            drawHandles(for: element, in: context)
        }
    }

    /// Handles are drawn in **view** space so they stay a constant physical size at any zoom.
    private func drawHandles(for element: AnnotationElement, in context: CGContext) {
        let bounds = transform.toView(AnnotationGeometry.bounds(of: element))
        guard !bounds.isNull, bounds.width > 0 else { return }

        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(bounds)
        context.setLineDash(phase: 0, lengths: [])

        for rect in SelectionHandles.rects(for: bounds).values {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.stroke(rect)
        }
        context.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        dragStart = point

        if model.tool == .select {
            beginSelectOrDrag(at: point, viewPoint: convert(event.locationInWindow, from: nil))
            return
        }
        if model.tool == .text {
            delegate?.canvas(self, beginTextEditingAt: point)
            return
        }
        if model.tool == .counter {
            model.edit {
                $0.add(.counter(CounterElement(centre: point,
                                               radius: 22 * max($0.scale, 1),
                                               fill: model.colour)))
            }
            delegate?.canvasDidEdit(self)
            return
        }
        if model.tool == .emoji {
            NSApp.orderFrontCharacterPalette(nil)
            return
        }

        model.beginGesture()
        if model.tool == .pencil { pencilPoints = [point] }
        needsDisplay = true
    }

    private func beginSelectOrDrag(at point: CGPoint, viewPoint: CGPoint) {
        if let selection = model.selection,
           let element = model.document.elements.first(where: { $0.id == selection }) {
            let viewBounds = transform.toView(AnnotationGeometry.bounds(of: element))
            if let handle = SelectionHandles.handle(at: viewPoint, bounds: viewBounds) {
                activeHandle = handle
                model.beginGesture()
                return
            }
        }
        model.selection = AnnotationGeometry.hitTest(model.document, at: point,
                                                     tolerance: tolerance)
        if model.selection != nil {
            moveOrigin = point
            model.beginGesture()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        guard let start = dragStart else { return }

        if model.tool == .select {
            dragSelection(to: point, viewPoint: convert(event.locationInWindow, from: nil))
            return
        }

        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        let stroke = StrokeStyle(colour: model.colour, width: model.scaledStrokeWidth)

        switch model.tool {
        case .arrow:
            draft = .arrow(ArrowElement(start: start, end: point, stroke: stroke))
        case .line:
            draft = .line(LineElement(start: start, end: point, stroke: stroke))
        case .rectangle:
            draft = .rectangle(ShapeElement(rect: rect, stroke: stroke))
        case .ellipse:
            draft = .ellipse(ShapeElement(rect: rect, stroke: stroke))
        case .highlighter:
            draft = .highlighter(HighlightElement(rect: rect, colour: model.colour))
        case .spotlight:
            draft = .spotlight(SpotlightElement(rect: rect))
        case .blur:
            draft = .blur(PixelFilterElement(rect: rect, mode: .secureBlur,
                                             radius: 24 * max(model.document.scale, 1),
                                             seed: UInt64(abs(rect.hashValue))))
        case .pixelate:
            draft = .pixelate(PixelFilterElement(rect: rect, mode: .pixellate,
                                                 radius: PixelFilters.minimumCellSize(
                                                    for: rect, scale: model.document.scale),
                                                 seed: UInt64(abs(rect.hashValue))))
        case .pencil:
            pencilPoints.append(point)
            draft = .pencil(PencilElement(points: pencilPoints, stroke: stroke))
        case .crop:
            draft = nil
            model.updateLive { $0.cropRect = rect }
        case .select, .text, .counter, .emoji:
            break
        }
        needsDisplay = true
    }

    private func dragSelection(to point: CGPoint, viewPoint: CGPoint) {
        guard let selection = model.selection,
              let index = model.document.elements.firstIndex(where: { $0.id == selection })
        else { return }

        if let handle = activeHandle {
            let current = AnnotationGeometry.bounds(of: model.document.elements[index])
            let resized = SelectionHandles.resize(
                current, handle: handle, to: point,
                constrainAspect: NSEvent.modifierFlags.contains(.shift),
                minimumSide: SelectionHandles.minimumSide)
            model.updateLive { document in
                Self.resize(&document.elements[index], from: current, to: resized)
            }
        } else if let origin = moveOrigin {
            let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            moveOrigin = point
            model.updateLive { document in
                Self.translate(&document.elements[index], by: delta)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draft = nil
            dragStart = nil
            pencilPoints = []
            activeHandle = nil
            moveOrigin = nil
            needsDisplay = true
        }

        if model.tool == .select {
            if activeHandle != nil || moveOrigin != nil { model.endGesture() }
            return
        }
        if model.tool == .crop {
            model.endGesture()
            delegate?.canvasDidEdit(self)
            return
        }

        guard var kind = draft else {
            // A click with no drag for a shape tool: nothing was drawn, so nothing is committed
            // and the open gesture is closed without an entry.
            if [.arrow, .line, .rectangle, .ellipse, .highlighter, .spotlight,
                .blur, .pixelate, .pencil].contains(model.tool) {
                model.endGesture()
            }
            return
        }

        // Simplify the stroke once, at commit: storing every mouse sample would bloat the file
        // and make the curve wobble.
        if case .pencil(var pencil) = kind {
            pencil.points = PencilSmoothing.simplify(pencil.points,
                                                     epsilon: 1.5 / transform.zoom)
            kind = .pencil(pencil)
        }

        let committed = kind
        model.updateLive { $0.add(committed) }
        model.endGesture()
        delegate?.canvasDidEdit(self)
    }

    // MARK: - Element transforms

    static func translate(_ element: inout AnnotationElement, by delta: CGSize) {
        func move(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.width, y: point.y + delta.height)
        }
        func move(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: delta.width, dy: delta.height) }

        switch element.kind {
        case .arrow(var value): value.start = move(value.start); value.end = move(value.end); element.kind = .arrow(value)
        case .line(var value): value.start = move(value.start); value.end = move(value.end); element.kind = .line(value)
        case .rectangle(var value): value.rect = move(value.rect); element.kind = .rectangle(value)
        case .ellipse(var value): value.rect = move(value.rect); element.kind = .ellipse(value)
        case .text(var value): value.origin = move(value.origin); element.kind = .text(value)
        case .highlighter(var value): value.rect = move(value.rect); element.kind = .highlighter(value)
        case .pencil(var value): value.points = value.points.map(move); element.kind = .pencil(value)
        case .spotlight(var value): value.rect = move(value.rect); element.kind = .spotlight(value)
        case .counter(var value): value.centre = move(value.centre); element.kind = .counter(value)
        case .blur(var value): value.rect = move(value.rect); element.kind = .blur(value)
        case .pixelate(var value): value.rect = move(value.rect); element.kind = .pixelate(value)
        case .emoji(var value): value.rect = move(value.rect); element.kind = .emoji(value)
        case .unknown: break
        }
    }

    /// Maps an element from one bounding box to another.
    static func resize(_ element: inout AnnotationElement, from: CGRect, to: CGRect) {
        guard from.width > 0, from.height > 0 else { return }
        let sx = to.width / from.width, sy = to.height / from.height
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: to.minX + (point.x - from.minX) * sx,
                    y: to.minY + (point.y - from.minY) * sy)
        }
        func map(_ rect: CGRect) -> CGRect {
            CGRect(origin: map(rect.origin),
                   size: CGSize(width: rect.width * sx, height: rect.height * sy))
        }

        switch element.kind {
        case .arrow(var value): value.start = map(value.start); value.end = map(value.end); element.kind = .arrow(value)
        case .line(var value): value.start = map(value.start); value.end = map(value.end); element.kind = .line(value)
        case .rectangle(var value): value.rect = map(value.rect); element.kind = .rectangle(value)
        case .ellipse(var value): value.rect = map(value.rect); element.kind = .ellipse(value)
        case .text(var value): value.origin = map(value.origin); element.kind = .text(value)
        case .highlighter(var value): value.rect = map(value.rect); element.kind = .highlighter(value)
        case .pencil(var value): value.points = value.points.map(map); element.kind = .pencil(value)
        case .spotlight(var value): value.rect = map(value.rect); element.kind = .spotlight(value)
        case .counter(var value):
            value.centre = map(value.centre)
            value.radius *= min(sx, sy)
            element.kind = .counter(value)
        case .blur(var value): value.rect = map(value.rect); element.kind = .blur(value)
        case .pixelate(var value): value.rect = map(value.rect); element.kind = .pixelate(value)
        case .emoji(var value): value.rect = map(value.rect); element.kind = .emoji(value)
        case .unknown: break
        }
    }
}
