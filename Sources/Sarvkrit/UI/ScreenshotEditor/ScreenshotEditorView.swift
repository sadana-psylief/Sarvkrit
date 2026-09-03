import AppKit
import SwiftUI

/// The editor's SwiftUI shell: toolbar, colours, inspector. The canvas itself is AppKit.
struct ScreenshotEditorView: View {
    @ObservedObject var model: EditorDocumentModel
    @ObservedObject var presets: BackgroundPresetStore
    @State private var showsBackgroundInspector = false
    let onSave: () -> Void
    let onSaveEditable: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.document.unknownCount > 0 { unknownBanner }
            HStack(spacing: 0) {
                AnnotationCanvasHost(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                if showsBackgroundInspector {
                    Divider()
                    BackgroundInspector(model: model, presets: presets)
                }
            }
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

    /// Tools in the groups they belong to, the way a drawing app arranges them.
    ///
    /// A single undifferentiated row of fourteen glyphs is a row you have to read every time. The
    /// separators mean the eye can go straight to "a shape", "some text", "hide something".
    private static let toolGroups: [[ToolKind]] = [
        [.select, .crop],
        [.arrow, .line, .rectangle, .ellipse],
        [.text, .counter, .emoji],
        [.pencil, .highlighter],
        [.blur, .pixelate, .spotlight],
    ]

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(Array(Self.toolGroups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 2) {
                    ForEach(group) { tool in toolButton(tool) }
                }
                .padding(2)
                .background(Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Divider().frame(height: 18)

            HStack(spacing: 5) {
                ForEach(Array(RGBAColour.palette.enumerated()), id: \.offset) { index, colour in
                    Button {
                        model.colour = colour
                        model.applyStyleToSelection()
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(cgColor: colour.cgColor) ?? .red))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(
                                    model.colour == colour
                                        ? Color(nsColor: NSColor(cgColor: colour.cgColor) ?? .red)
                                        : .clear,
                                    lineWidth: 2)
                                    .padding(-3))
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help("Colour \(index + 1)")
                }
            }

            if model.tool == .arrow {
                arrowStylePicker
            }

            HStack(spacing: 6) {
                Image(systemName: "lineweight")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $model.strokeWidth, in: 2...36) { editing in
                    if !editing { model.applyStyleToSelection() }
                }
                .frame(width: 84)
            }
            .help("Line thickness")

            Spacer(minLength: 8)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo  (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo  (⇧⌘Z)")

            Button { showsBackgroundInspector.toggle() } label: {
                Image(systemName: "square.on.square.badge.person.crop")
                    .frame(width: 26, height: 20)
                    .background(showsBackgroundInspector ? Color.accentColor : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(showsBackgroundInspector ? Color.white : Color.primary)
            }
            .help("Background")

            Button(action: onCopy) { Image(systemName: "doc.on.doc") }.help("Copy  (⌘C)")
            Button(action: onSaveEditable) { Image(systemName: "square.and.pencil") }
                .help("Save so it stays editable  (⇧⌘S)")
            Button("Done", action: onSave)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Save  (⌘S)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
    }

    /// The four arrow shapes, drawn rather than named.
    ///
    /// Names would be guesswork — "filled" and "thin" mean nothing until you see them — so each
    /// button draws the actual path the tool will produce, at the thickness currently set.
    private var arrowStylePicker: some View {
        HStack(spacing: 2) {
            ForEach([ArrowElement.Head.filled, .open, .thin, .curved], id: \.self) { head in
                Button {
                    model.arrowHead = head
                    model.applyStyleToSelection()
                } label: {
                    ArrowStyleSwatch(head: head, isActive: model.arrowHead == head)
                        .frame(width: 34, height: 20)
                        .background(model.arrowHead == head ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help("Arrow style")
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func toolButton(_ tool: ToolKind) -> some View {
        let isActive = model.tool == tool
        return Button { model.tool = tool } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 20)
                .background(isActive ? Color.accentColor : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help(tool.key.map { "\(tool.title)  (\($0.uppercased()))" } ?? tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
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
    }
}

/// A miniature of one arrow style, drawn with the same geometry the tool uses so the button
/// cannot promise a shape the canvas won't draw.
struct ArrowStyleSwatch: NSViewRepresentable {
    let head: ArrowElement.Head
    let isActive: Bool

    func makeNSView(context: Context) -> SwatchView { SwatchView(head: head, isActive: isActive) }

    func updateNSView(_ view: SwatchView, context: Context) {
        view.head = head
        view.isActive = isActive
    }

    final class SwatchView: NSView {
        var head: ArrowElement.Head { didSet { needsDisplay = true } }
        var isActive: Bool { didSet { needsDisplay = true } }

        init(head: ArrowElement.Head, isActive: Bool) {
            self.head = head
            self.isActive = isActive
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let colour = isActive ? NSColor.white : NSColor.labelColor
            let start = CGPoint(x: bounds.minX + 5, y: bounds.midY)
            let end = CGPoint(x: bounds.maxX - 5, y: bounds.midY)

            switch ArrowGeometry.shape(from: start, to: end, curvature: 0,
                                       head: head, strokeWidth: 3.2) {
            case .fill(let path):
                context.setFillColor(colour.cgColor)
                context.addPath(path)
                context.fillPath()
            case .stroke(let path, let lineWidth):
                context.setStrokeColor(colour.cgColor)
                context.setLineWidth(lineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.addPath(path)
                context.strokePath()
            }
        }
    }
}
