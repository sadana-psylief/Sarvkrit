import AppKit
import Combine
import CoreGraphics
import Foundation

/// The editable state of one open capture.
///
/// Holds the document, the undo history, the selection and the active tool. Testable without a
/// window: every mutation here is a function of values, and the view observes rather than owns.
@MainActor
final class EditorDocumentModel: ObservableObject {

    /// The capture this came from, so saving can write back to the right history entry.
    let historyItemID: UUID?
    let base: CGImage

    @Published private(set) var document: AnnotationDocument
    @Published var tool: ToolKind = .select
    @Published var selection: AnnotationElement.ID?
    @Published var colour: RGBAColour = .red
    @Published var strokeWidth: CGFloat = 6
    /// Which arrow shape new arrows get. Four were built; without this control the user could
    /// only ever draw the first one.
    @Published var arrowHead: ArrowElement.Head = .filled
    /// Which of the seven styles new text gets. Same reasoning as `arrowHead`: the styles exist,
    /// and without a control the user could only ever type the first one.
    @Published var textPreset: TextPreset = .standard
    /// Which emoji the next click places. See `EmojiCatalogue` for why the tool cannot just open
    /// the system palette.
    @Published var emoji: String = EmojiCatalogue.default
    /// Nil means "fit to the window", which is the state the editor opens in and returns to.
    /// A concrete value is a zoom the user chose and should not be silently overridden on resize.
    @Published var zoom: CGFloat?
    /// Set while a text annotation has the field editor. Gates the single-key tool shortcuts.
    @Published var isEditingText = false
    @Published private(set) var isDirty = false

    let filterCache = PixelFilterCache()

    private var undoStack: UndoStack<AnnotationDocument>

    init(base: CGImage, document: AnnotationDocument? = nil, historyItemID: UUID? = nil) {
        self.base = base
        self.historyItemID = historyItemID
        let initial = document ?? AnnotationDocument(
            imageSize: CGSize(width: base.width, height: base.height))
        self.document = initial
        self.undoStack = UndoStack(initial: initial)
    }

    // MARK: - Tool defaults

    /// Defaults scaled to the capture.
    ///
    /// **Multiplied by `document.scale` once, at creation, and never again.** Every stored length
    /// is in image pixels, so a 6pt-looking stroke on a 2× capture is 12 — get this wrong and
    /// annotations are half-size on Retina and correct on a 1× external display, which reads as a
    /// rendering bug rather than a units one.
    var scaledStrokeWidth: CGFloat { strokeWidth * max(document.scale, 1) }
    var scaledFontSize: CGFloat { 36 * max(document.scale, 1) }

    // MARK: - Editing

    /// Applies a change and records one undo step.
    func edit(_ change: (inout AnnotationDocument) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }
        undoStack.commit(next)
        document = undoStack.current
        isDirty = true
    }

    /// Mutates without recording — for the live part of a drag. Pair with `endGesture`.
    func updateLive(_ change: (inout AnnotationDocument) -> Void) {
        var next = document
        change(&next)
        document = next
    }

    /// Opens a gesture: everything until `endGesture` collapses into one undo step.
    func beginGesture() { undoStack.beginTransaction() }

    func endGesture() {
        undoStack.endTransaction(document)
        document = undoStack.current
        isDirty = true
    }

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }

    func undo() {
        guard let value = undoStack.undo() else { return }
        document = value
        filterCache.invalidate()
        pruneSelection()
    }

    func redo() {
        guard let value = undoStack.redo() else { return }
        document = value
        filterCache.invalidate()
        pruneSelection()
    }

    /// A selection pointing at an element that undo removed would leave handles floating over
    /// nothing.
    private func pruneSelection() {
        if let selection, !document.elements.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }

    /// Applies the current colour, thickness and arrow style to whatever is selected.
    ///
    /// Without this the toolbar only affects the *next* mark, so changing your mind about a colour
    /// means deleting and redrawing — which is the difference between a toolbar and a preference.
    /// Retargets the selected emoji, so picking a different one restyles it rather than only
    /// affecting the next placement — which is how every other control in the toolbar behaves.
    func applyEmojiToSelection() {
        guard let selection else { return }
        guard let index = document.elements.firstIndex(where: { $0.id == selection }),
              case .emoji = document.elements[index].kind else { return }
        edit { document in
            guard case .emoji(var value) = document.elements[index].kind else { return }
            value.emoji = self.emoji
            document.elements[index].kind = .emoji(value)
        }
    }

    func applyStyleToSelection() {
        guard let selection else { return }
        edit { document in
            guard let index = document.elements.firstIndex(where: { $0.id == selection })
            else { return }
            let colour = self.colour
            let width = self.scaledStrokeWidth
            switch document.elements[index].kind {
            case .arrow(var value):
                value.stroke.colour = colour
                value.stroke.width = width
                // Picking "Curved" on a straight arrow gives it the default bow; picking any other
                // style takes it away. Without this the style button would appear to do nothing,
                // which is why the bow used to be substituted at render time instead.
                if self.arrowHead == .curved, ArrowGeometry.isStraight(value.curvature) {
                    value.curvature = ArrowGeometry.defaultCurvature(from: value.start,
                                                                     to: value.end)
                } else if self.arrowHead != .curved {
                    value.curvature = 0
                }
                value.head = self.arrowHead
                document.elements[index].kind = .arrow(value)
            case .line(var value):
                value.stroke.colour = colour; value.stroke.width = width
                document.elements[index].kind = .line(value)
            case .rectangle(var value):
                value.stroke.colour = colour; value.stroke.width = width
                document.elements[index].kind = .rectangle(value)
            case .ellipse(var value):
                value.stroke.colour = colour; value.stroke.width = width
                document.elements[index].kind = .ellipse(value)
            case .pencil(var value):
                value.stroke.colour = colour; value.stroke.width = width
                document.elements[index].kind = .pencil(value)
            case .text(var value):
                // Restyling has to go through the preset, not set the colour alone: on a boxed
                // style the picked colour is the box, and writing it into `colour` would put red
                // text on a red pill.
                self.textPreset.apply(to: &value, accent: colour)
                document.elements[index].kind = .text(value)
            case .highlighter(var value):
                // Tinted, for the same reason the canvas tints it when creating one — see
                // `RGBAColour.asMarker`.
                value.colour = colour.asMarker
                document.elements[index].kind = .highlighter(value)
            case .counter(var value):
                value.fill = colour
                value.textColour = colour.readableForeground
                document.elements[index].kind = .counter(value)
            default:
                break
            }
        }
    }

    func deleteSelection() {
        guard let selection else { return }
        edit { $0.remove(id: selection) }
        self.selection = nil
    }

    func duplicateSelection() {
        guard let selection,
              let element = document.elements.first(where: { $0.id == selection }) else { return }
        edit { document in
            var copy = element
            copy.id = UUID()
            copy.z = (document.elements.map(\.z).max() ?? 0) + 1
            document.elements.append(copy)
            document.renumberCounters()
        }
    }

    // MARK: - Output

    static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]

    func zoomIn() {
        let current = zoom ?? 1
        zoom = Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last
    }

    func zoomOut() {
        let current = zoom ?? 1
        zoom = Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first
    }

    /// The finished image, annotations only.
    func flatten() -> CGImage? {
        AnnotationRenderer.flatten(document, base: base)
    }

    /// The finished image with its background, which is what save and copy produce.
    ///
    /// The background is composited *after* flattening rather than being another element, because
    /// it changes the canvas size — every annotation coordinate would have to shift if it were
    /// part of the document's own space.
    func flattenWithBackground() -> CGImage? {
        guard let flattened = flatten() else { return nil }
        guard let background = document.background else { return flattened }
        return BackgroundCompositor.render(flattened, style: background) ?? flattened
    }

    func markSaved() { isDirty = false }
}
