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
                    GradientSwatch(spec: entry.spec)
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
    let spec: GradientSpec

    func makeNSView(context: Context) -> SwatchView { SwatchView(spec: spec) }
    func updateNSView(_ view: SwatchView, context: Context) { view.spec = spec }

    final class SwatchView: NSView {
        var spec: GradientSpec { didSet { needsDisplay = true } }
        init(spec: GradientSpec) {
            self.spec = spec
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            BackgroundCompositor.draw(spec, in: bounds, context: context)
        }
    }
}
