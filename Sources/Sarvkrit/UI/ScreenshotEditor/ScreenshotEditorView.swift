import AppKit
import SwiftUI

/// The editor's SwiftUI shell: toolbar, colours, inspector. The canvas itself is AppKit.
struct ScreenshotEditorView: View {
    @ObservedObject var model: EditorDocumentModel
    let onSave: () -> Void
    let onSaveEditable: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.document.unknownCount > 0 { unknownBanner }
            AnnotationCanvasHost(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// An older build must say what it is carrying rather than appear to have lost it.
    private var unknownBanner: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("""
                \(model.document.unknownCount) annotation\(model.document.unknownCount == 1 ? "" : "s") \
                made by a newer version of Sarvkrit. They're kept when you save, but not shown here.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(.quaternary.opacity(0.4))
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.md) {
            HStack(spacing: 2) {
                ForEach(ToolKind.allCases) { tool in
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.symbolName)
                            .frame(width: 26, height: 24)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.22)
                                                           : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help(tool.key.map { "\(tool.title)  (\($0.uppercased()))" } ?? tool.title)
                }
            }

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                ForEach(Array(RGBAColour.palette.enumerated()), id: \.offset) { index, colour in
                    Button { model.colour = colour } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(cgColor: colour.cgColor) ?? .red))
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(
                                model.colour == colour ? Color.primary : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help("Colour \(index + 1)")
                }
            }

            Slider(value: $model.strokeWidth, in: 2...32)
                .frame(width: 90)
                .help("Line thickness")

            Spacer(minLength: 0)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo  (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo  (⇧⌘Z)")
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }.help("Copy  (⌘C)")
            Button(action: onSave) { Image(systemName: "square.and.arrow.down") }.help("Save  (⌘S)")
            Button(action: onSaveEditable) { Image(systemName: "square.and.pencil") }
                .help("Save so it stays editable  (⇧⌘S)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
    }
}

/// Hosts the AppKit canvas and keeps it in step with the model.
struct AnnotationCanvasHost: NSViewRepresentable {
    @ObservedObject var model: EditorDocumentModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(model: model)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.refresh()
    }

    @MainActor
    final class Coordinator: AnnotationCanvasDelegate {
        private let model: EditorDocumentModel
        init(model: EditorDocumentModel) { self.model = model }

        func canvasDidEdit(_ view: AnnotationCanvasView) {
            view.refresh()
        }

        /// Text needs a real caret, which is the one thing a drawing surface cannot provide — so
        /// an `NSTextField` is put over the canvas for the duration of the edit and committed on
        /// blur. While it is up, `isEditingText` gates the single-key tool shortcuts.
        func canvas(_ view: AnnotationCanvasView, beginTextEditingAt point: CGPoint) {
            let scale = max(model.document.scale, 1)
            model.edit {
                $0.add(.text(TextElement(origin: point,
                                         string: "Text",
                                         fontSize: 36 * scale,
                                         colour: model.colour)))
            }
            model.selection = model.document.elements.last?.id
            view.refresh()
        }
    }
}
