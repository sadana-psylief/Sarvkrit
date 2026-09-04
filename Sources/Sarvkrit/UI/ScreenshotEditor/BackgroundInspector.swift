import AppKit
import SwiftUI

/// The Background tool's controls.
struct BackgroundInspector: View {
    @ObservedObject var model: EditorDocumentModel
    @ObservedObject var presets: BackgroundPresetStore
    @State private var presetName = ""

    private var style: CaptureBackground { model.document.background ?? CaptureBackground() }

    private func update(_ change: (inout CaptureBackground) -> Void) {
        var next = style
        change(&next)
        model.edit { $0.background = next }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Toggle("Add a background", isOn: Binding(
                    get: { model.document.background != nil },
                    set: { on in model.edit { $0.background = on ? CaptureBackground() : nil } }))

                // **The presets show whether or not one is applied.** Gating them behind the
                // toggle meant opening the panel showed a single unticked checkbox and nothing
                // else — no sign that twenty gradients were behind it, and no reason to guess
                // that ticking the box was worth doing. Picking a swatch turns it on.
                swatches
                if model.document.background != nil {
                    meshEditor
                    controls
                    presetControls
                }
            }
            .padding(Theme.Space.md)
        }
        .frame(width: 240)
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                  spacing: 6) {
            ForEach(BackgroundCatalogue.entries) { entry in
                Button { update { $0.fill = .builtIn(id: entry.id) } } label: {
                    GradientSwatch(mesh: entry.mesh)
                        .frame(height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(isSelected(entry) ? Color.accentColor : .clear,
                                          lineWidth: 2))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help(entry.name)
            }
        }
    }

    /// The applied background's control grid, as editable colours.
    ///
    /// **A preset is a starting point, not a fixed choice.** Twenty gradients is a good catalogue
    /// and still the wrong colour for someone's brand; without this the only way past them is to
    /// leave. Editing any well turns a `.builtIn` into a `.mesh` carrying the same colours, so the
    /// change is a continuation of the preset rather than a fresh start — and picking a swatch
    /// again puts it back.
    ///
    /// Laid out as the mesh is: row 0 at the top, matching what the renderer draws, so a well sits
    /// where its colour appears.
    @ViewBuilder private var meshEditor: some View {
        if let mesh = style.fill.editableMesh {
            VStack(alignment: .leading, spacing: 6) {
                Text("Colours").font(.caption).foregroundStyle(.secondary)
                // Square cells, packed left: at three-to-a-row across the full panel the wells
                // were letterboxed bars and read as a list. Square and tight, the grid is a
                // low-resolution picture of the gradient above it, which is what it is.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<mesh.rows, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(0..<mesh.columns, id: \.self) { column in
                                MeshColourWell(
                                    colour: mesh.colour(column: column, row: row),
                                    label: "Row \(row + 1), column \(column + 1)"
                                ) { colour in
                                    setColour(colour, column: column, row: row)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Reads the *current* mesh rather than the one the row was built from.
    ///
    /// The system colour panel stays open across edits and holds this closure, so a captured mesh
    /// would go stale: pick a colour on one cell with the panel still up, drag the panel's wheel,
    /// and the drag would write its cell onto the mesh from before — reverting the other edit.
    private func setColour(_ colour: RGBAColour, column: Int, row: Int) {
        guard var next = style.fill.editableMesh else { return }
        let index = row * next.columns + column
        guard next.colours.indices.contains(index) else { return }
        next.colours[index] = colour
        update { $0.fill = .mesh(next) }
    }

    private func isSelected(_ entry: BackgroundCatalogue.Entry) -> Bool {
        if case .builtIn(let id) = style.fill { return id == entry.id }
        return false
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            labelled("Padding", value: "\(Int(style.padding))") {
                Slider(value: Binding(get: { style.padding },
                                      set: { value in update { $0.padding = value } }),
                       in: 0...240)
            }
            labelled("Corners", value: "\(Int(style.cornerRadius))") {
                Slider(value: Binding(get: { style.cornerRadius },
                                      set: { value in update { $0.cornerRadius = value } }),
                       in: 0...64)
            }
            Toggle("Shadow", isOn: Binding(
                get: { style.shadow != nil },
                set: { on in update { $0.shadow = on ? CaptureBackground.Shadow() : nil } }))
            Picker("Shape", selection: Binding(get: { style.aspect },
                                               set: { value in update { $0.aspect = value } })) {
                ForEach(AspectRatio.allCases) { Text($0.title).tag($0) }
            }
            Button("Auto Balance") {
                model.edit { $0.background = BackgroundCompositor.autoBalanced(model.base) }
            }
            .help("Pick a background and padding that suit this screenshot")
        }
    }

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Divider()
            if !presets.presets.isEmpty {
                ForEach(presets.presets) { preset in
                    HStack {
                        Button(preset.name) { model.edit { $0.background = preset.style } }
                            .buttonStyle(.link)
                        Spacer()
                        Button { presets.remove(id: preset.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .help("Delete “\(preset.name)”")
                        .accessibilityLabel("Delete preset \(preset.name)")
                    }
                    .font(.caption)
                }
            }
            HStack {
                TextField("Preset name", text: $presetName)
                Button("Save") {
                    guard !presetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    presets.add(name: presetName, style: style)
                    presetName = ""
                }
            }
            .font(.caption)
        }
    }

    private func labelled<Content: View>(_ title: String, value: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

/// A gradient preview, drawn from the same spec the compositor uses so the swatch cannot drift
/// from the result.
struct GradientSwatch: NSViewRepresentable {
    let mesh: MeshSpec

    func makeNSView(context: Context) -> SwatchView { SwatchView(mesh: mesh) }
    func updateNSView(_ view: SwatchView, context: Context) { view.mesh = mesh }

    final class SwatchView: NSView {
        var mesh: MeshSpec { didSet { needsDisplay = true } }
        init(mesh: MeshSpec) {
            self.mesh = mesh
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        /// **Flipped, like every other consumer of the compositor.** The export context is turned
        /// top-left and `AnnotationCanvasView` overrides this too; this view did not, so it drew
        /// the same fill upside down. With two symmetric stops at 135° that was near-invisible,
        /// which is how it survived — a mesh with distinct corners makes it obvious, and a swatch
        /// that mirrors the result is a picker that lies.
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            BackgroundCompositor.draw(mesh, in: bounds, context: context)
        }
    }
}


/// One control point of a mesh, and the palette behind it.
///
/// Its own type rather than `ColourWell`, which reads and writes `EditorDocumentModel.colour` —
/// the *annotation* colour — and so cannot address a cell of a grid. The palette itself is shared:
/// the same `AnnotationPalette` and the same `NSColorPanel` bridge, so a background colour can be
/// sampled off the screen with the eyedropper exactly like an arrow's can.
struct MeshColourWell: View {
    let colour: RGBAColour
    let label: String
    var onChange: (RGBAColour) -> Void

    @State private var isShowingPalette = false

    var body: some View {
        Button { isShowingPalette.toggle() } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: NSColor(cgColor: colour.cgColor) ?? .gray))
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $isShowingPalette, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6),
                          spacing: 8) {
                    ForEach(Array(AnnotationPalette.colours.enumerated()), id: \.offset) { index, swatch in
                        Button { onChange(swatch) } label: {
                            Circle()
                                .fill(Color(nsColor: NSColor(cgColor: swatch.cgColor) ?? .gray))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor),
                                                               lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .help(AnnotationPalette.name(at: index))
                    }
                }
                Divider()
                Button {
                    let panel = NSColorPanel.shared
                    panel.showsAlpha = false
                    panel.color = NSColor(cgColor: colour.cgColor) ?? .gray
                    panel.setTarget(ColourPanelBridge.shared)
                    panel.setAction(#selector(ColourPanelBridge.colourChanged(_:)))
                    ColourPanelBridge.shared.onChange = onChange
                    panel.makeKeyAndOrderFront(nil)
                } label: {
                    Label("Other Colour…", systemImage: "eyedropper.halffull")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .clickableCursor()
            }
            .padding(12)
            .frame(width: 214)
        }
    }
}
