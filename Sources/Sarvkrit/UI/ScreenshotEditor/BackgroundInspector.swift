import AppKit
import SwiftUI

/// The Background tool's controls.
struct BackgroundInspector: View {
    @ObservedObject var model: EditorDocumentModel
    @ObservedObject var presets: BackgroundPresetStore
    @ObservedObject var wallpapers: WallpaperStore = .shared
    @State private var presetName = ""
    @State private var isNamingPreset = false
    @State private var showsEveryGradient = false
    /// The frame the user last had, so "None" does not throw their padding away.
    @State private var remembered = CaptureBackground()

    private var style: CaptureBackground { model.document.background ?? remembered }

    private func update(_ change: (inout CaptureBackground) -> Void) {
        var next = style
        change(&next)
        // Auto Balance is a standing preference, not a past click: with it on, changing anything
        // re-derives the fill and padding from the capture rather than leaving a stale choice.
        if next.isAutoBalanced {
            next = BackgroundCompositor.autoBalanced(model.base, base: next)
        }
        remembered = next
        model.edit { $0.background = next }
    }

    /// Applies a fill, turning the background on if it was off.
    private func choose(_ fill: CaptureBackground.Fill) {
        update { $0.fill = fill }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                presetControls
                noneButton

                // **The swatches show whether or not a background is applied.** Gating them
                // behind a checkbox meant opening the panel showed one unticked box and nothing
                // else — no sign that twenty gradients were behind it, and no reason to guess
                // that ticking it was worth doing. Picking any swatch turns it on.
                section("Gradients", trailing: { gradientDisclosure }) { gradientSwatches }
                section("Wallpapers") { wallpaperSwatches }
                section("Blurred") { blurredSwatches }
                section("Plain colour") { plainColours }

                if model.document.background != nil {
                    meshEditor
                    controls
                }
            }
            .padding(Theme.Space.md)
        }
        .frame(width: 240)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private var noneButton: some View {
        Button {
            // Nil, not a `.none` fill: to a user "None" means no frame at all, and a transparent
            // border with a shadow round it is a third state nobody asked for. The frame itself
            // is remembered, so picking a fill again brings back the padding and corners rather
            // than resetting them — which is the actual complaint about the old checkbox.
            model.edit { $0.background = nil }
        } label: {
            Text("None").frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .clickableCursor()
        .disabled(model.document.background == nil)
    }

    @ViewBuilder private var gradientDisclosure: some View {
        if BackgroundCatalogue.entries.count > Self.collapsedGradientCount {
            Button(showsEveryGradient ? "Show less" : "Show more") {
                showsEveryGradient.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .clickableCursor()
        }
    }

    /// Two rows collapsed. Twenty swatches pushed every slider below the fold, so the padding and
    /// shadow controls were invisible until you scrolled past a wall of gradients.
    private static let collapsedGradientCount = 10

    private var gradientSwatches: some View {
        let entries = showsEveryGradient
            ? BackgroundCatalogue.entries
            : Array(BackgroundCatalogue.entries.prefix(Self.collapsedGradientCount))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                         spacing: 6) {
            ForEach(entries) { entry in
                Button { choose(.builtIn(id: entry.id)) } label: {
                    GradientSwatch(mesh: entry.mesh)
                        .frame(height: 30)
                        .modifier(SwatchChrome(isSelected: isSelected(entry)))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help(entry.name)
            }
        }
    }

    private var wallpaperSwatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                  spacing: 6) {
            ForEach(wallpapers.fileNames, id: \.self) { name in
                Button { choose(.image(fileName: name)) } label: {
                    FillSwatch(fill: .image(fileName: name),
                               sources: .init(wallpaper: wallpapers.image(named: name)))
                        .frame(height: 30)
                        .modifier(SwatchChrome(isSelected: isWallpaperSelected(name)))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help(name)
                .contextMenu {
                    Button("Remove", role: .destructive) { removeWallpaper(name) }
                }
            }
            Button(action: importWallpaper) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor),
                                      style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .help("Add an image")
            .accessibilityLabel("Add a wallpaper")
        }
    }

    private var blurredSwatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                  spacing: 6) {
            ForEach(BlurredBackdropPresets.all, id: \.name) { preset in
                Button { choose(.blurred(preset.blur)) } label: {
                    FillSwatch(fill: .blurred(preset.blur), sources: .init(base: model.base))
                        .frame(height: 30)
                        .modifier(SwatchChrome(isSelected: isBlurSelected(preset.blur)))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help("\(preset.name) — made from this screenshot")
            }
        }
    }

    private var plainColours: some View {
        VStack(alignment: .leading, spacing: 6) {
            colourRow(BackgroundPalette.solid, names: BackgroundPalette.solidNames)
            colourRow(BackgroundPalette.pastel, names: BackgroundPalette.pastelNames)
        }
    }

    private func colourRow(_ colours: [RGBAColour], names: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(colours.enumerated()), id: \.offset) { index, colour in
                Button { choose(.solid(colour)) } label: {
                    Circle()
                        .fill(Color(nsColor: NSColor(cgColor: colour.cgColor) ?? .white))
                        .frame(width: 20, height: 20)
                        // Not `separatorColor` at a half point: white and mist are near enough to
                        // the panel that a hairline loses them entirely, and an invisible swatch
                        // is one you cannot pick.
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                        .overlay(Circle()
                            .strokeBorder(isSolidSelected(colour) ? Color.accentColor : .clear,
                                          lineWidth: 2)
                            .padding(-3))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help(index < names.count ? names[index] : "Colour")
            }
        }
    }

    // MARK: - Selection

    private func isWallpaperSelected(_ name: String) -> Bool {
        if case .image(let fileName) = style.fill, model.document.background != nil {
            return fileName == name
        }
        return false
    }

    private func isBlurSelected(_ blur: CaptureBackground.Blur) -> Bool {
        if case .blurred(let current) = style.fill, model.document.background != nil {
            return current == blur
        }
        return false
    }

    private func isSolidSelected(_ colour: RGBAColour) -> Bool {
        if case .solid(let current) = style.fill, model.document.background != nil {
            return current == colour
        }
        return false
    }

    // MARK: - Wallpapers

    private func importWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = WallpaperStore.readableTypes
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let name = wallpapers.add(contentsOf: url) else { return }
        choose(.image(fileName: name))
    }

    private func removeWallpaper(_ name: String) {
        // If the document is using it, drop back to a gradient rather than leaving it pointing at
        // a file that is now gone.
        if isWallpaperSelected(name) { choose(.builtIn(id: "dusk")) }
        wallpapers.remove(name)
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
            labelled("Inset", value: "\(Int(style.inset))") {
                Slider(value: Binding(get: { style.inset },
                                      set: { value in update { $0.inset = value } }),
                       in: 0...200)
            }
            .help("Shrink the screenshot without growing the canvas")

            Toggle("Auto balance", isOn: Binding(
                get: { style.isAutoBalanced },
                set: { on in
                    // Written straight rather than through `update`, which would re-balance on
                    // the way *out* as well and make turning it off do nothing visible.
                    var next = style
                    next.isAutoBalanced = on
                    if on { next = BackgroundCompositor.autoBalanced(model.base, base: next) }
                    remembered = next
                    model.edit { $0.background = next }
                }))
            .help("Keep the background and padding suited to this screenshot")

            labelled("Shadow", value: "\(Int(shadowAmount))") {
                Slider(value: Binding(get: { shadowAmount },
                                      set: { value in update { $0.shadow = Self.shadow(value) } }),
                       in: 0...100)
            }
            labelled("Corners", value: "\(Int(style.cornerRadius))") {
                Slider(value: Binding(get: { style.cornerRadius },
                                      set: { value in update { $0.cornerRadius = value } }),
                       in: 0...64)
            }

            HStack(alignment: .top, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alignment").font(.caption).foregroundStyle(.secondary)
                    alignmentGrid
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ratio").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { style.aspect },
                                                  set: { value in update { $0.aspect = value } })) {
                        ForEach(AspectRatio.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    /// The shadow as one 0-100 number.
    ///
    /// The panel offered a bare on/off switch while `Shadow` carried four properties nobody could
    /// reach, so the only shadow available was the default one. Radius and opacity move together
    /// here because they are one perceptual thing — "how much shadow" — and separate sliders for
    /// them is a lighting rig, not a screenshot tool. Zero means off, so the toggle is still in
    /// there at the end of the track.
    private var shadowAmount: Double {
        guard let shadow = style.shadow else { return 0 }
        return min(shadow.radius / 0.8, 100)
    }

    private static func shadow(_ amount: Double) -> CaptureBackground.Shadow? {
        guard amount > 0.5 else { return nil }
        return CaptureBackground.Shadow(radius: amount * 0.8,
                                        offsetY: amount * 0.4,
                                        opacity: 0.12 + amount / 100 * 0.33)
    }

    /// Nine anchors, laid out as the thing they describe.
    ///
    /// A picker listing "Top Leading, Top, Top Trailing…" makes you read nine phrases and build
    /// the grid in your head. The grid *is* the control.
    private var alignmentGrid: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { column in
                        let alignment = Self.alignments[row * 3 + column]
                        Button { update { $0.alignment = alignment } } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(style.alignment == alignment
                                      ? Color.accentColor
                                      : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                                .frame(width: 20, height: 16)
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .help(Self.alignmentNames[row * 3 + column])
                        .accessibilityLabel(Self.alignmentNames[row * 3 + column])
                    }
                }
            }
        }
    }

    private static let alignments: [CaptureBackground.Alignment] = [
        .topLeading, .top, .topTrailing,
        .leading, .centre, .trailing,
        .bottomLeading, .bottom, .bottomTrailing,
    ]
    private static let alignmentNames = [
        "Top left", "Top", "Top right",
        "Left", "Centre", "Right",
        "Bottom left", "Bottom", "Bottom right",
    ]

    /// Saved looks: a menu and a "+", rather than a growing list of links.
    ///
    /// The list was fine at two presets and pushed every gradient below the fold at ten. A menu
    /// costs one line whatever it holds, which is the shape the reference uses for the same
    /// reason.
    private var presetControls: some View {
        HStack(spacing: 6) {
            Menu {
                if presets.presets.isEmpty {
                    Text("No saved backgrounds")
                } else {
                    ForEach(presets.presets) { preset in
                        Button(preset.name) {
                            remembered = preset.style
                            model.edit { $0.background = preset.style }
                        }
                    }
                    Divider()
                    Menu("Delete") {
                        ForEach(presets.presets) { preset in
                            Button(preset.name) { presets.remove(id: preset.id) }
                        }
                    }
                }
            } label: {
                Text(presets.presets.isEmpty ? "Presets…" : "Presets (\(presets.presets.count))")
            }

            Button {
                presetName = ""
                isNamingPreset = true
            } label: {
                Image(systemName: "plus")
            }
            .clickableCursor()
            .help("Save this background as a preset")
            .accessibilityLabel("Save preset")
            .popover(isPresented: $isNamingPreset) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save background").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $presetName)
                        .frame(width: 160)
                        .onSubmit(savePreset)
                    HStack {
                        Spacer()
                        Button("Cancel") { isNamingPreset = false }
                        Button("Save", action: savePreset)
                            .keyboardShortcut(.defaultAction)
                            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
            }
        }
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        presets.add(name: name, style: style)
        presetName = ""
        isNamingPreset = false
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

/// The rounded corners and selection ring every swatch in this panel wears.
///
/// One modifier rather than the same four lines on each grid, because a swatch that rounds
/// differently from its neighbour is the kind of thing nobody reports and everybody sees.
struct SwatchChrome: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

/// A preview of any fill, drawn through the compositor.
///
/// `GradientSwatch` can only show a mesh, and three of the picker's sections are not meshes. This
/// takes the `Fill` itself and hands it to `BackgroundCompositor.drawFill` — the same call the
/// export makes — so a wallpaper thumbnail and a blurred backdrop are previews of the real thing
/// rather than approximations of it. `SwatchAgreementTests` pins that property for the mesh
/// swatch; the reason it holds here is that there is only one drawing routine to agree with.
struct FillSwatch: NSViewRepresentable {
    let fill: CaptureBackground.Fill
    let sources: BackgroundCompositor.Sources

    func makeNSView(context: Context) -> SwatchView { SwatchView(fill: fill, sources: sources) }

    func updateNSView(_ view: SwatchView, context: Context) {
        view.fill = fill
        view.sources = sources
    }

    final class SwatchView: NSView {
        var fill: CaptureBackground.Fill { didSet { needsDisplay = true } }
        var sources: BackgroundCompositor.Sources { didSet { needsDisplay = true } }

        init(fill: CaptureBackground.Fill, sources: BackgroundCompositor.Sources) {
            self.fill = fill
            self.sources = sources
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        /// Flipped, like every other consumer of the compositor — see `GradientSwatch`, which
        /// shipped upside down for exactly as long as its stops were symmetric enough to hide it.
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            BackgroundCompositor.drawFill(fill, in: bounds, context: context, sources: sources)
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
