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
