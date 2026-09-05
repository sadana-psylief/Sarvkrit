import SwiftUI

/// The canvas tab: background, padding, radius, shadow.
///
/// Deliberately the same vocabulary as `BackgroundInspector` on the screenshot side, because it is
/// the same model underneath — a person who has styled a screenshot already knows this panel.
struct CanvasInspector: View {
    @ObservedObject var model: StudioDocumentModel

    private var shortSide: CGFloat {
        min(model.project.canvasSize.width, model.project.canvasSize.height)
    }

    var body: some View {
        SectionHeader("Background")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                  spacing: 6) {
            ForEach(BackgroundCatalogue.entries) { entry in
                Button {
                    model.edit { $0.background.fill = .builtIn(id: entry.id) }
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: entry.mesh.colours.prefix(3).map {
                            Color(nsColor: NSColor(cgColor: $0.cgColor) ?? .gray)
                        }, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isSelected(entry.id)
                                              ? Color.accentColor : .clear, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .help(entry.name)
                .accessibilityLabel(entry.name)
            }
        }

        SectionHeader("Shape")
        slider("Padding", value: Binding(
            get: { model.project.background.padding },
            set: { value in model.editLive { $0.background.padding = value } }),
               range: 0...(shortSide / 2))
        slider("Corner radius", value: Binding(
            get: { model.project.background.cornerRadius },
            set: { value in model.editLive { $0.background.cornerRadius = value } }),
               range: 0...(shortSide / 4))
        slider("Inset", value: Binding(
            get: { model.project.background.inset },
            set: { value in model.editLive { $0.background.inset = value } }),
               range: 0...(shortSide / 6))

        Toggle("Shadow", isOn: Binding(
            get: { model.project.background.shadow != nil },
            set: { on in
                model.edit { $0.background.shadow = on ? CaptureBackground.Shadow() : nil }
            }))
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func isSelected(_ id: String) -> Bool {
        if case .builtIn(let current) = model.project.background.fill { return current == id }
        return false
    }

    private func slider(_ title: String, value: Binding<CGFloat>,
                        range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in
                if editing { model.beginGesture() } else { model.endGesture() }
            }
        }
    }
}

/// The cursor tab.
struct CursorInspector: View {
    @ObservedObject var model: StudioDocumentModel

    var body: some View {
        SectionHeader("Cursor")

        Toggle("Hide the cursor", isOn: Binding(
            get: { model.project.cursor.isHidden },
            set: { value in model.edit { $0.cursor.isHidden = value } }))
        .toggleStyle(.switch).controlSize(.small)

        VStack(alignment: .leading, spacing: 2) {
            Text("Size").font(.system(size: Theme.Typography.caption)).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { model.project.cursor.size },
                set: { value in model.editLive { $0.cursor.size = value } }),
                   in: 0.5...3) { editing in
                if editing { model.beginGesture() } else { model.endGesture() }
            }
        }

        Picker("Smoothing", selection: Binding(
            get: { model.project.cursor.smoothing },
            set: { value in model.edit { $0.cursor.smoothing = value } })) {
            ForEach(CursorSmoothing.allCases, id: \.self) { Text($0.title).tag($0) }
        }

        Picker("Click effect", selection: Binding(
            get: { model.project.cursor.clickEffect },
            set: { value in model.edit { $0.cursor.clickEffect = value } })) {
            ForEach(ClickEffectStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }

        Toggle("Hide when it stops moving", isOn: Binding(
            get: { model.project.cursor.hidesWhenIdle },
            set: { value in model.edit { $0.cursor.hidesWhenIdle = value } }))
        .toggleStyle(.switch).controlSize(.small)

        SectionHeader("Zooms")
        HStack {
            Button("Re-detect") { model.redetectZooms() }
            Spacer()
            Text("\(model.project.zooms.count)")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
        }
        // Says what the button will and will not touch, because a destructive-sounding action with
        // no explanation is one people never press.
        Text("Replaces the zooms Sarvkrit found. Ones you made or edited are left alone.")
            .font(.system(size: Theme.Typography.caption))
            .foregroundStyle(.secondary)
    }
}
