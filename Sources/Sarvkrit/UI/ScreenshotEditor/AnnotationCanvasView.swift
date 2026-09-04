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
}

final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
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
        recomputeTransform()
        needsDisplay = true
    }

    func refresh() {
        // The background changes the size of the whole composition, so the fit has to be redone
        // whenever the document does — not only when the window resizes.
        recomputeTransform()
        needsDisplay = true
    }

    /// Where the screenshot sits inside its background. `.zero`-origin when there isn't one.
    private var imageRect: CGRect = .zero

    private func recomputeTransform() {
        let composition = AnnotationRenderer.composition(for: model.document)
        imageRect = composition.imageRect
        // Inset so the composition never touches the window edge — a background with a shadow
        // needs air around it or it reads as a rendering artefact rather than a deliberate frame.
        let available = bounds.insetBy(dx: 24, dy: 24).size
        let fitted = CanvasTransform.fitting(imageSize: composition.canvasSize,
                                             in: CGSize(width: max(available.width, 1),
                                                        height: max(available.height, 1)))
        // A zoom the user chose wins over the fit, but the image stays centred either way — a
        // zoomed image pinned to a corner is much harder to work on than one in the middle.
        let scale = model.zoom ?? fitted.zoom
        transform = CanvasTransform(
            imageSize: composition.canvasSize,
            zoom: scale,
            offset: CGPoint(x: (bounds.width - composition.canvasSize.width * scale) / 2,
                            y: (bounds.height - composition.canvasSize.height * scale) / 2))
    }

    /// The zoom the canvas is currently drawn at, so the toolbar can show it.
    var currentZoom: CGFloat { transform.zoom }

    /// View point → **image** coordinates, which is what every annotation is stored in.
    ///
    /// Two steps, because with a background the canvas is larger than the image: view → canvas,
    /// then canvas → image by subtracting where the image sits inside it. Missing the second step
    /// would put every annotation off by the padding.
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let canvasPoint = transform.toImage(convert(event.locationInWindow, from: nil))
        return CGPoint(x: canvasPoint.x - imageRect.minX, y: canvasPoint.y - imageRect.minY)
    }

    private var tolerance: CGFloat { transform.imageTolerance(forViewTolerance: 6) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let composition = AnnotationRenderer.composition(for: model.document)

        context.saveGState()
        context.translateBy(x: transform.offset.x, y: transform.offset.y)
        context.scaleBy(x: transform.zoom, y: transform.zoom)

        // The background is drawn here rather than only at export, which is the whole point:
        // choosing one has to show you what you are choosing.
        AnnotationRenderer.drawBackground(model.document,
                                          canvasSize: composition.canvasSize,
                                          imageRect: composition.imageRect,
                                          in: context)

        var shown = model.document
        // The in-progress mark is drawn but never stored, so an abandoned drag leaves nothing.
        if let draft { shown.elements.append(AnnotationElement(z: .max, kind: draft)) }

        context.saveGState()
        if let style = model.document.background {
            context.addPath(BackgroundCompositor.clipPath(imageRect: composition.imageRect,
                                                          style: style))
            context.clip()
        }
        context.translateBy(x: composition.imageRect.minX, y: composition.imageRect.minY)
        // Under the marks, not over them: the halo has to peek out around the arrow's silhouette
        // the way a glow does, rather than wash a translucent blue across the arrow's own colour.
        if let selection = model.selection,
           let element = model.document.elements.first(where: { $0.id == selection }),
           case .arrow(let arrow) = element.kind {
            drawArrowHalo(arrow, in: context)
        }
        AnnotationRenderer.draw(shown, base: model.base, in: context,
                                filterCache: model.filterCache, quality: .interactive)
        context.restoreGState()
        context.restoreGState()

        if let selection = model.selection,
           let element = model.document.elements.first(where: { $0.id == selection }) {
            drawHandles(for: element, in: context)
        }
    }

    /// A glow tracing the selected arrow's outline.
    ///
    /// An arrow gets no dashed box — a rectangle implies a resize it does not have — which left
    /// nothing at all saying it was selected except three small handles. This traces the actual
    /// silhouette instead, head included.
    ///
    /// Drawn by stroking the *fill* path: a centred stroke puts half the width outside the
    /// silhouette and half inside, and the arrow then paints over the inside half. So the visible
    /// glow is half the line width, and the line width is in image pixels — hence the division by
    /// zoom, which keeps the glow a constant size on screen however far the canvas is zoomed.
    private func drawArrowHalo(_ arrow: ArrowElement, in context: CGContext) {
        let glow: CGFloat = 5                       // view points, each side
        let path: CGPath
        switch ArrowGeometry.shape(from: arrow.start, to: arrow.end,
                                   curvature: arrow.curvature,
                                   head: arrow.head, strokeWidth: arrow.stroke.width) {
        case .fill(let filled):
            path = filled
        case .stroke(let stroked, let lineWidth):
            // The open style is a thin chevron, so its halo has to clear its own stroke too.
            path = stroked.copy(strokingWithWidth: lineWidth, lineCap: .round,
                                lineJoin: .round, miterLimit: 10)
        }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(glow * 2 / max(transform.zoom, 0.01))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Handles are drawn in **view** space so they stay a constant physical size at any zoom.
    /// The handles for an element, in view coordinates.
    ///
    /// An arrow gets its two ends and a bow; everything else gets the eight around its box. An
    /// arrow given box handles could be stretched but never bent, and neither end could be moved
    /// without moving the other.
    private func viewHandles(for element: AnnotationElement,
                             bounds: CGRect) -> [SelectionHandles.Handle: CGRect] {
        guard case .arrow(let arrow) = element.kind else {
            return SelectionHandles.rects(for: bounds)
        }
        func toView(_ point: CGPoint) -> CGPoint {
            transform.toView(CGPoint(x: point.x + imageRect.minX, y: point.y + imageRect.minY))
        }
        let bow = SelectionHandles.bowPoint(start: arrow.start, end: arrow.end,
                                            curvature: arrow.curvature)
        return SelectionHandles.arrowHandles(start: toView(arrow.start), end: toView(arrow.end),
                                             curvature: 0)
            .merging([.curve: CGRect(x: toView(bow).x - SelectionHandles.defaultSize / 2,
                                     y: toView(bow).y - SelectionHandles.defaultSize / 2,
                                     width: SelectionHandles.defaultSize,
                                     height: SelectionHandles.defaultSize)]) { _, new in new }
    }

    private func drawHandles(for element: AnnotationElement, in context: CGContext) {
        let inImage = AnnotationGeometry.bounds(of: element)
        let bounds = transform.toView(inImage.offsetBy(dx: imageRect.minX, dy: imageRect.minY))
        guard !bounds.isNull, bounds.width > 0 else { return }

        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1)
        // No dashed box round an arrow: the three handles say what is selected, and a rectangle
        // implies a resize behaviour it does not have.
        if case .arrow = element.kind {} else {
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(bounds)
            context.setLineDash(phase: 0, lengths: [])
        }

        let isArrow: Bool
        if case .arrow = element.kind { isArrow = true } else { isArrow = false }

        for (handle, rect) in viewHandles(for: element, bounds: bounds) {
            // An arrow's handles move points; a box's handles resize. Round says the first,
            // square says the second, and an arrow has no square handles at all.
            //
            // The bow is a different colour again, because it is the only handle whose job you
            // cannot guess: the two ends obviously move the ends, and nothing about a third grip
            // sitting on the line says "drag me sideways and the arrow bends".
            let round = isArrow || handle == .curve
            context.setFillColor(handle == .curve
                                 ? NSColor.systemPink.cgColor : NSColor.white.cgColor)
            context.setStrokeColor(handle == .curve
                                   ? NSColor.white.cgColor : NSColor.controlAccentColor.cgColor)
            if round {
                context.fillEllipse(in: rect)
                context.strokeEllipse(in: rect)
            } else {
                context.fill(rect)
                context.stroke(rect)
            }
        }
        context.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        dragStart = point

        if model.tool == .select {
            if event.clickCount == 2,
               let hit = AnnotationGeometry.hitTest(model.document, at: point,
                                                    tolerance: tolerance),
               let element = model.document.elements.first(where: { $0.id == hit }),
               case .text = element.kind {
                editText(hit)
                return
            }
            beginSelectOrDrag(at: point, viewPoint: convert(event.locationInWindow, from: nil))
            return
        }
        if model.tool == .text {
            beginTextEditing(at: point)
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
            // Sized like the counter beside it, and in image pixels — a 4× capture needs a 4×
            // emoji or it lands as a speck. See the note on scale in `AnnotationDocument`.
            let side = 64 * max(model.document.scale, 1)
            let rect = CGRect(x: point.x - side / 2, y: point.y - side / 2,
                              width: side, height: side)
            model.edit { $0.add(.emoji(EmojiElement(rect: rect, emoji: model.emoji))) }
            model.selection = model.document.elements.last?.id
            delegate?.canvasDidEdit(self)
            needsDisplay = true
            return
        }

        model.beginGesture()
        if model.tool == .pencil { pencilPoints = [point] }
        needsDisplay = true
    }

    private func beginSelectOrDrag(at point: CGPoint, viewPoint: CGPoint) {
        if let selection = model.selection,
           let element = model.document.elements.first(where: { $0.id == selection }) {
            let viewBounds = transform.toView(
                AnnotationGeometry.bounds(of: element)
                    .offsetBy(dx: imageRect.minX, dy: imageRect.minY))
            let handles = viewHandles(for: element, bounds: viewBounds)
            // Corners first, as `SelectionHandles.handle` does — at a small selection they overlap
            // the edges, and the corner is the one being reached for.
            if let hit = handles.first(where: { $0.key.isCorner && $0.value.contains(viewPoint) })
                ?? handles.first(where: { $0.value.contains(viewPoint) }) {
                activeHandle = hit.key
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
            // The curved style's bow is written here, once, rather than substituted on every
            // read — that is what lets the bow handle drag it back to straight.
            draft = .arrow(ArrowElement(
                start: start, end: point,
                curvature: model.arrowHead == .curved
                    ? ArrowGeometry.defaultCurvature(from: start, to: point) : 0,
                head: model.arrowHead, stroke: stroke))
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

        // An arrow's handles move points, not a bounding box, so they are applied before the
        // box path — `SelectionHandles.resize` returns the bounds unchanged for these.
        if let handle = activeHandle,
           case .arrow(let arrow) = model.document.elements[index].kind,
           handle == .start || handle == .end || handle == .curve {
            model.updateLive { document in
                guard case .arrow(var value) = document.elements[index].kind else { return }
                switch handle {
                case .start: value.start = point
                case .end: value.end = point
                default:
                    // The only place in the app that writes curvature. Projected onto the chord's
                    // normal, so dragging along the arrow does nothing and dragging onto the chord
                    // gives exactly zero — which is how a curve is taken back to straight.
                    value.curvature = SelectionHandles.curvature(forBowAt: point,
                                                                 start: value.start,
                                                                 end: value.end)
                }
                document.elements[index].kind = .arrow(value)
            }
            _ = arrow
            needsDisplay = true
            return
        }

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

    // MARK: - Text editing

    /// The field editor sitting over the canvas while a text annotation is typed.
    ///
    /// **A real `NSTextField`, not a prompt or a fixed string.** A drawing surface cannot host a
    /// caret, so text is the one tool that needs a genuine control laid over it — which is also
    /// why the canvas is an `NSView` rather than a SwiftUI `Canvas`. The first version of this
    /// dropped the literal word "Text" on the image with no way to change it.
    private var textEditor: NSTextField?
    private var editingElementID: AnnotationElement.ID?

    private func beginTextEditing(at point: CGPoint) {
        commitTextEditing()

        let scale = max(model.document.scale, 1)
        var element = TextElement(origin: point,
                                  string: "",
                                  fontSize: 30 * scale,
                                  colour: model.colour)
        model.textPreset.apply(to: &element, accent: model.colour)

        model.edit { $0.add(.text(element)) }
        guard let added = model.document.elements.last else { return }
        editingElementID = added.id
        model.selection = added.id
        presentEditor(for: element, at: point)
    }

    /// Reopens the editor on an existing element, for a double-click.
    func editText(_ id: AnnotationElement.ID) {
        guard let element = model.document.elements.first(where: { $0.id == id }),
              case .text(let text) = element.kind else { return }
        commitTextEditing()
        editingElementID = id
        model.selection = id
        presentEditor(for: text, at: text.origin)
    }

    private func presentEditor(for element: TextElement, at point: CGPoint) {
        let field = NSTextField(frame: .zero)
        field.stringValue = element.string
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14)
        field.focusRingType = .none
        field.delegate = self
        // The field is what the user types into, so it has to look like the result — same face,
        // same size, same colour. Resolving through the typeface rather than the name is what
        // makes the rounded and monospaced presets look right while being typed.
        field.font = element.typeface.font(ofSize: element.fontSize * transform.zoom,
                                           customName: element.fontName)
        field.textColor = NSColor(cgColor: element.colour.cgColor) ?? .red
        field.placeholderString = "Type…"

        let origin = transform.toView(CGPoint(x: point.x + imageRect.minX,
                                              y: point.y + imageRect.minY))
        let height = element.fontSize * transform.zoom * 1.4
        field.frame = NSRect(x: origin.x - 4, y: origin.y - 4,
                             width: max(160, bounds.maxX - origin.x - 24), height: height)

        addSubview(field)
        textEditor = field
        model.isEditingText = true
        window?.makeFirstResponder(field)
    }

    /// Writes the typed string back and takes the field away.
    ///
    /// An empty string removes the element rather than leaving an invisible one behind for the
    /// user to trip over with the select tool later.
    func commitTextEditing() {
        guard let field = textEditor, let id = editingElementID else { return }
        let typed = field.stringValue

        field.removeFromSuperview()
        textEditor = nil
        editingElementID = nil
        model.isEditingText = false

        model.edit { document in
            guard let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
            if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document.elements.remove(at: index)
                return
            }
            if case .text(var text) = document.elements[index].kind {
                text.string = typed
                document.elements[index].kind = .text(text)
            }
        }
        if model.document.elements.first(where: { $0.id == id }) == nil { model.selection = nil }
        needsDisplay = true
        delegate?.canvasDidEdit(self)
    }

    override func resignFirstResponder() -> Bool {
        commitTextEditing()
        return super.resignFirstResponder()
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

extension AnnotationCanvasView {
    /// Return commits the text; Escape abandons it. Both matter — without them the only way out
    /// of the field is clicking elsewhere, which is not obvious while a caret is blinking at you.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commitTextEditing()
            window?.makeFirstResponder(self)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            textEditorStringForCancel()
            window?.makeFirstResponder(self)
            return true
        default:
            return false
        }
    }

    /// Escape throws away what was typed, which for a brand-new element means removing it.
    private func textEditorStringForCancel() {
        (subviews.compactMap { $0 as? NSTextField }.first)?.stringValue = ""
        commitTextEditing()
    }
}
