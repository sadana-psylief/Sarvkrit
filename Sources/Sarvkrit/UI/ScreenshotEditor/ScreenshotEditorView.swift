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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .fixedSize(horizontal: false, vertical: true)
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
            // The canvas takes every spare point and the bars hug their content. Without this the
            // bottom bar claimed the leftover height and the canvas filled half the window with a
            // pale slab underneath it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
            bottomBar
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
        .background(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
    }

    // MARK: - Toolbar

    /// Two rows: what you draw with, then what you draw it in and what you do with it.
    ///
    /// **One row could not hold it once the tools were named.** Fourteen labelled tools plus the
    /// colour well, the style pickers, the thickness slider and the file actions come to well over
    /// a thousand points, so on any ordinary window most of the palette scrolled out of sight —
    /// which is the same "I could not find it" this labelling was meant to end. Splitting by what
    /// the controls are *for* halves the width and reads better than the single strip did.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(Self.toolGroups.enumerated()), id: \.offset) { _, group in
                            HStack(spacing: 2) {
                                ForEach(group) { tool in toolButton(tool) }
                            }
                            .padding(2)
                            .background(groupBackground)
                        }

                    }
                    .padding(.vertical, 1)
                }
            }

            HStack(spacing: 10) {
                // Leading on the options row, where it belongs: a background is a property of the
                // whole picture, not a thing you draw with. It used to be wedged into the *file
                // actions* between Redo and Copy — so scanning the palette for it failed — with
                // `square.on.square.badge.person.crop` for a glyph, which is AppKit's
                // profile-picture symbol and reads as "user photo".
                backgroundButton
                    .padding(2)
                    .background(groupBackground)

                ColourWell(model: model)

                if model.tool == .arrow { arrowStylePicker }
                if model.tool == .text { textStylePicker }
                if model.tool == .emoji {
                    EmojiPicker(model: model)
                        .padding(2)
                        .background(groupBackground)
                }

                HStack(spacing: 6) {
                    Image(systemName: "lineweight")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $model.strokeWidth, in: 2...36) { editing in
                        if !editing { model.applyStyleToSelection() }
                    }
                    .frame(width: 80)
                    .accessibilityLabel("Line thickness")
                }
                .help("Line thickness")

                Spacer(minLength: 0)

                // Priority on the trailing group: adding the arrow-style picker once pushed Undo
                // through Done straight off the end of the window, so the actions you always need
                // were the first thing to disappear.
                trailingActions
                    .layoutPriority(2)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 8)
        // Explicit, because a hosting view is transparent by default and the bar came out black
        // in a light window.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The background tool, shown as what it makes.
    ///
    /// A gradient swatch rather than a symbol: the feature's whole output is a coloured surround,
    /// so a picture of one says more than any glyph, and it is the only hint in the toolbar that
    /// twenty presets exist behind the button.
    private var backgroundButton: some View {
        Button { showsBackgroundInspector.toggle() } label: {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.98, green: 0.36, blue: 0.31),
                                 Color(red: 0.55, green: 0.20, blue: 0.85)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 14, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                Text("Background")
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 34)
            .padding(.horizontal, 7)
            .background(showsBackgroundInspector ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(showsBackgroundInspector ? Color.white
                                                      : Color(nsColor: .labelColor))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help("Background — padding, shadow and 20 presets")
        .accessibilityLabel("Background")
        .accessibilityAddTraits(showsBackgroundInspector ? [.isSelected] : [])
    }

    private var groupBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
    }

    private var trailingActions: some View {
        HStack(spacing: 9) {
            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 20)
            }
            .disabled(!model.canUndo).help("Undo  (⌘Z)").accessibilityLabel("Undo")
            Button { model.redo() } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 24, height: 20)
            }
            .disabled(!model.canRedo).help("Redo  (⇧⌘Z)").accessibilityLabel("Redo")

            // Framed, because a bare glyph's hover target is the glyph's own bounding box —
            // about 13pt, which is a tooltip most people never manage to trigger.
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc").frame(width: 24, height: 20)
            }
            .help("Copy  (⌘C)")
            .accessibilityLabel("Copy")
            Button(action: onSaveEditable) {
                Image(systemName: "square.and.pencil").frame(width: 24, height: 20)
            }
            .help("Save so it stays editable  (⇧⌘S)")
            .accessibilityLabel("Save so it stays editable")
            Button("Done", action: onSave)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Save  (⌘S)")
        }
    }

    /// Icon *and* name, which is what the rest of this app does and what the editor was missing.
    ///
    /// `AllInOnePickerView` — the capture bar nobody complained about — is icon plus
    /// `Text(mode.title)` plus a tooltip. This was a near-copy of that cell with the text taken
    /// out, and fourteen unlabelled glyphs is what "other features in that annotation place is not
    /// clear" was about. The tooltip was already here; a tooltip is a fallback, not a label.
    private func toolButton(_ tool: ToolKind) -> some View {
        let isActive = model.tool == tool
        return Button { model.tool = tool } label: {
            VStack(spacing: 2) {
                Image(systemName: tool.symbolName)
                    .font(.system(size: 12, weight: .medium))
                Text(tool.title)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    // Sized to the word, not to a guess. A fixed 46pt truncated "Highlighter" to
                    // "Highligh…", which is a label that has stopped being one.
                    .fixedSize()
            }
            .frame(minWidth: 46)
            .frame(height: 34)
            .padding(.horizontal, 5)
            .background(isActive ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(isActive ? Color.white : Color(nsColor: .labelColor))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help(tool.key.map { "\(tool.title)  (\($0.uppercased()))" } ?? tool.title)
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// The four arrow shapes, drawn rather than named.
    ///
    /// Names would be guesswork — "filled" and "thin" mean nothing until you see them — so each
    /// button draws the actual path the tool will produce.
    private var arrowStylePicker: some View {
        HStack(spacing: 2) {
            ForEach([ArrowElement.Head.filled, .open, .thin, .curved], id: \.self) { head in
                Button {
                    model.arrowHead = head
                    model.applyStyleToSelection()
                } label: {
                    ArrowStyleSwatch(head: head, isActive: model.arrowHead == head)
                        .frame(width: 30, height: 20)
                        .background(model.arrowHead == head ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help("\(head.title) arrow")
                .accessibilityLabel("\(head.title) arrow")
            }
        }
        .padding(2)
        .background(groupBackground)
    }

    /// The seven text styles, shown *as themselves*.
    ///
    /// A menu of the words "Standard / Rounded / Monospaced / Outlined…" would be useless — the
    /// whole difference between them is what they look like, so each row renders in its own style.
    /// A menu rather than a row of swatches because seven legible previews do not fit in a
    /// toolbar next to everything else.
    private var textStylePicker: some View {
        Menu {
            ForEach(TextPreset.allCases) { preset in
                Button {
                    model.textPreset = preset
                    model.applyStyleToSelection()
                } label: {
                    // The tick has to be drawn, not implied: a Menu row with a custom label gets
                    // no selection mark of its own.
                    Label {
                        TextStyleSwatch(preset: preset, accent: model.colour)
                    } icon: {
                        Image(systemName: model.textPreset == preset ? "checkmark" : "")
                    }
                }
            }
        } label: {
            TextStyleSwatch(preset: model.textPreset, accent: model.colour)
                .frame(minWidth: 92)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(2)
        .background(groupBackground)
        .help("Text style")
    }

    // MARK: - Bottom bar

    /// Zoom on the left, a drag-out handle in the middle.
    ///
    /// The handle matters more than it looks: it is the answer to "I have annotated this, now get
    /// it into Slack" without saving a file first. Dragging the canvas itself would fight the
    /// annotation tools for the same gesture, so the proxy is a separate, obvious target.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            // The readout *is* the reset control. A separate "Fit" button beside a label that
            // already said "Fit" was two of the same word doing one job.
            Button { model.zoom = nil } label: {
                Text(zoomLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(model.zoom == nil ? Color.secondary
                                                       : Color(nsColor: .labelColor))
                    .frame(width: 52)
            }
            .disabled(model.zoom == nil)
            .help("Fit the whole image in the window")
            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")

            Spacer()
            EditorDragOut(model: model)
            Spacer()

            Text(DimensionReadout.text(for: model.document.contentRect.size))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var zoomLabel: String {
        guard let zoom = model.zoom else { return "Fit" }
        return "\(Int((zoom * 100).rounded()))%"
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
            // Resolved against this view's effective appearance, or a dark-mode label colour gets
            // used in a light window and the swatch disappears.
            let colour = isActive
                ? NSColor.white
                : NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
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

/// The "drag me" handle in the editor's bottom bar.
///
/// Writes the flattened, annotated image to a temporary file and drags *that*, because Finder and
/// most apps want a `public.file-url` — `ShelfDragSource` learned the same thing the hard way, and
/// an in-memory image drop quietly does nothing.
struct EditorDragOut: NSViewRepresentable {
    @ObservedObject var model: EditorDocumentModel

    func makeNSView(context: Context) -> DragOutView {
        let view = DragOutView()
        view.model = model
        return view
    }

    func updateNSView(_ view: DragOutView, context: Context) { view.model = model }

    final class DragOutView: NSView, NSDraggingSource {
        weak var model: EditorDocumentModel?

        override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 22) }

        override func draw(_ dirtyRect: NSRect) {
            let label = NSAttributedString(string: "⇠  Drag me  ⇢", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = label.size()
            let box = bounds.insetBy(dx: 0, dy: (bounds.height - 22) / 2)
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: box, xRadius: 11, yRadius: 11).fill()
            label.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
        }

        /// Swallowed so `mouseDragged` arrives — the same split `WindowDragHandle` documents.
        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            guard let model, let image = model.flattenWithBackground(),
                  let data = try? CaptureDocumentFile.encodeFlat(image) else { return }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Screenshot-\(UUID().uuidString.prefix(8)).png")
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }

            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil),
                                         size: NSSize(width: 96, height: 96)),
                                  contents: NSImage(cgImage: image,
                                                    size: NSSize(width: image.width,
                                                                 height: image.height)))
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}
