import AppKit
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

/// Masks and highlights.
struct MaskInspector: View {
    @ObservedObject var model: StudioDocumentModel

    var body: some View {
        SectionHeader("Masks")
        Button("Add one here") { model.addMaskAtPlayhead() }

        if model.project.masks.isEmpty {
            Text("Cover something you don't want in the recording — an API key, a customer name, "
                 + "a sidebar.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
        }

        ForEach(model.project.masks) { mask in
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Picker("", selection: Binding(
                    get: { mask.mode },
                    set: { value in model.setMaskMode(mask.id, value) })) {
                    ForEach(StudioMask.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()

                // **Said, not implied.** A person choosing "Blur" over a password should be told
                // that it comes back — the README makes this argument at length and the UI is
                // where it has to land.
                if let caveat = mask.mode.caveat {
                    Label(caveat, systemImage: "exclamationmark.triangle")
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text(String(format: "%.1fs – %.1fs", mask.start, mask.end))
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.removeMask(mask.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).clickableCursor()
                        .accessibilityLabel("Remove this mask")
                }
            }
            .padding(.vertical, Theme.Space.xs)
            ModuleSeparator()
        }
    }
}

/// The camera.
struct CameraInspector: View {
    @ObservedObject var model: StudioDocumentModel

    var body: some View {
        SectionHeader("Camera")
        Picker("Shape", selection: Binding(
            get: { model.project.camera.shape },
            set: { value in model.edit { $0.camera.shape = value } })) {
            ForEach(CameraSettings.Shape.allCases, id: \.self) { Text($0.title).tag($0) }
        }

        Picker("While zoomed", selection: Binding(
            get: { model.project.camera.sizeDuringZoom },
            set: { value in model.edit { $0.camera.sizeDuringZoom = value } })) {
            ForEach(CameraSettings.ZoomSizing.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        // The default is the one people do not expect, so it says why.
        Text("A zoom exists to show something. The camera getting smaller keeps it out of the way.")
            .font(.system(size: Theme.Typography.caption))
            .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 2) {
            Text("Size").font(.system(size: Theme.Typography.caption)).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { model.project.camera.sizeFraction },
                set: { value in model.editLive { $0.camera.sizeFraction = value } }),
                   in: 0.1...0.4) { editing in
                if editing { model.beginGesture() } else { model.endGesture() }
            }
        }

        Toggle("Mirror", isOn: Binding(
            get: { model.project.camera.mirrored },
            set: { value in model.edit { $0.camera.mirrored = value } }))
        .toggleStyle(.switch).controlSize(.small)
    }
}

/// Captions, and the transcript that produces them.
struct CaptionsInspector: View {
    @ObservedObject var model: StudioDocumentModel
    @State private var vocabulary = ""
    @State private var isWorking = false
    @State private var problem: String?

    var body: some View {
        SectionHeader("Captions")

        if model.project.captions.isEmpty {
            TextField("Words to expect", text: $vocabulary)
                .textFieldStyle(.roundedBorder)
            // Three lines of code, and the difference between "Sarvkrit" and "sav credit".
            Text("Product names, library names, jargon — anything a recogniser would guess wrong.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)

            Button(isWorking ? "Working…" : "Write captions") { transcribe() }
                .disabled(isWorking)

            Text("Worked out on this Mac. Nothing is uploaded.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
        } else {
            Text("\(model.project.captions.count) lines")
                .font(.system(size: Theme.Typography.body))
            Toggle("Highlight word by word", isOn: Binding(
                get: { model.project.captionStyle.highlight == .word },
                set: { value in
                    model.edit { $0.captionStyle.highlight = value ? .word : .none }
                }))
            .toggleStyle(.switch).controlSize(.small)
            Button("Export subtitles…") { exportSubtitles() }
        }

        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.orange)
        }
    }

    private func transcribe() {
        isWorking = true
        problem = nil
        let words = vocabulary.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        Task {
            do {
                try await model.transcribe(vocabulary: words)
            } catch Transcriber.TranscriptionError.onDeviceUnavailable(let locale) {
                // Said plainly, and nothing is sent anywhere as a fallback. That is the whole
                // point of choosing this API over one that would quietly succeed.
                problem = "No offline model for \(locale). Sarvkrit won't upload your audio to "
                    + "work around it."
            } catch Transcriber.TranscriptionError.noAudio {
                problem = "This recording has no microphone track."
            } catch {
                problem = "Couldn't write captions."
            }
            isWorking = false
        }
    }

    private func exportSubtitles() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Captions.srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Transcriber.subtitles(model.project.captions, format: .srt)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Keystrokes, and the audio-derived edits.
struct KeystrokesInspector: View {
    @ObservedObject var model: StudioDocumentModel

    var body: some View {
        SectionHeader("Keystrokes")
        Toggle("Show the keys I pressed", isOn: Binding(
            get: { model.project.keystrokes.isEnabled },
            set: { value in model.edit { $0.keystrokes.isEnabled = value } }))
        .toggleStyle(.switch).controlSize(.small)

        Toggle("Include single keys", isOn: Binding(
            get: { model.project.keystrokes.showsBareKeys },
            set: { value in model.edit { $0.keystrokes.showsBareKeys = value } }))
        .toggleStyle(.switch).controlSize(.small)
        Text("Off by default: ⌘C and ⌃⇧R are what a demo needs to show. Nothing typed into a "
             + "password field was recorded either way.")
            .font(.system(size: Theme.Typography.caption))
            .foregroundStyle(.secondary)

        SectionHeader("Tidy up")
        let suggestions = model.typingSuggestions
        if suggestions.isEmpty {
            Text("No typing worth speeding up in this one.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
        } else {
            Button("Speed up \(suggestions.count) typing \(suggestions.count == 1 ? "part" : "parts")") {
                model.applyAllTypingSuggestions()
            }
            Text("Watching someone type is boring at 1×. Suggested, not applied — undo works.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
        }

        Button("Remove silences") { model.removeSilencesFromMicrophone() }
            .disabled(!FileManager.default.fileExists(atPath: model.bundle.microphoneURL.path))
    }
}

/// Device frames.
struct DeviceFrameInspector: View {
    @ObservedObject var model: StudioDocumentModel

    var body: some View {
        SectionHeader("Device frame")
        Picker("Frame", selection: Binding(
            get: { model.project.deviceFrame.frameID ?? "" },
            set: { value in
                model.edit { $0.deviceFrame.frameID = value.isEmpty ? nil : value }
            })) {
            Text("None").tag("")
            ForEach(DeviceFrame.all) { Text($0.name).tag($0.id) }
        }

        if let resolved = model.project.deviceFrame.resolved() {
            Picker("Colour", selection: Binding(
                get: { model.project.deviceFrame.colourwayID ?? resolved.colourway.id },
                set: { value in model.edit { $0.deviceFrame.colourwayID = value } })) {
                ForEach(resolved.frame.colourways) { Text($0.name).tag($0.id) }
            }
        }
    }
}
