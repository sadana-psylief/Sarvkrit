import AppKit
import SwiftUI

/// The canvas tab: background, padding, radius, shadow.
///
/// Deliberately the same vocabulary as `BackgroundInspector` on the screenshot side, because it is
/// the same model underneath — a person who has styled a screenshot already knows this panel.
struct CanvasInspector: View {
    @ObservedObject var model: StudioDocumentModel

    private var selectedClip: Clip? {
        model.project.timeline.clips.first { $0.id == model.selectedClip }
    }

    private var shortSide: CGFloat {
        min(model.project.canvasSize.width, model.project.canvasSize.height)
    }

    var body: some View {
        SectionHeader("Fades")
        seconds("Fade in", value: Binding(
            get: { model.project.fadeIn },
            set: { value in model.editLive { $0.fadeIn = value } }),
               range: 0...3)
        seconds("Fade out", value: Binding(
            get: { model.project.fadeOut },
            set: { value in model.editLive { $0.fadeOut = value } }),
               range: 0...3)
        Text("The picture fades up from black and down to it, and the sound fades with it.")
            .font(.system(size: Theme.Typography.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let clip = selectedClip {
            SectionHeader("The Selected Clip")
            seconds("Speed", value: Binding(
                get: { clip.speed },
                set: { value in model.updateClip(clip.id, live: true) { $0.speed = value } }),
                   range: Clip.speedRange)
            seconds("Hold last frame", value: Binding(
                get: { clip.hold },
                set: { value in model.updateClip(clip.id, live: true) { $0.hold = value } }),
                   range: 0...5)
            // Only meaningful where there is a cut before this clip.
            if model.project.timeline.clips.first?.id != clip.id {
                seconds("Dip to black at its cut", value: Binding(
                    get: { clip.dipToBlack },
                    set: { value in
                        model.updateClip(clip.id, live: true) { $0.dipToBlack = value }
                    }),
                       range: 0...1.5)
            }
            Text("Hold keeps the last frame on screen — useful for pausing on a result while you "
                 + "talk over it.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

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

    /// The same, for the timings — `Binding<CGFloat>` and `Binding<Double>` are not
    /// interchangeable even though the values are.
    private func seconds(_ title: String, value: Binding<Double>,
                         range: ClosedRange<Double>) -> some View {
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

/// Pictures brought in and composited over the recording.
struct MediaInspector: View {
    @ObservedObject var model: StudioDocumentModel

    private var selected: MediaOverlay? {
        model.project.mediaOverlays.first { $0.id == model.selectedMedia }
            ?? model.project.mediaOverlays.first { $0.covers(model.sourceTime) }
    }

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.image]
            panel.message = "The picture is copied into the recording, so the project keeps "
                + "working if you move the original."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if !model.addMediaAtPlayhead(from: url) {
                ToastPresenter.shared.show("Couldn't bring that picture in",
                                           symbolName: "photo.badge.exclamationmark")
            }
        } label: {
            Label("Bring in a Picture…", systemImage: "photo.badge.plus")
        }

        if model.project.mediaOverlays.isEmpty {
            Text("A logo, a screenshot, a diagram. It is copied into the recording so the project "
                 + "opens anywhere, and sits below any text.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let overlay = selected {
            SectionHeader("The Selected Picture")
            seconds("Size", value: Binding(
                get: { overlay.rect.width },
                set: { value in
                    model.updateMedia(overlay.id, live: true) {
                        // Kept square in canvas terms; the picture is fitted inside, never
                        // stretched, so the box only decides how much room it has.
                        $0.rect.size = CGSize(width: value, height: value)
                    }
                }),
                    range: 0.05...1)
            seconds("Across", value: Binding(
                get: { overlay.rect.minX },
                set: { value in model.updateMedia(overlay.id, live: true) { $0.rect.origin.x = value } }),
                    range: 0...1)
            seconds("Down", value: Binding(
                get: { overlay.rect.minY },
                set: { value in model.updateMedia(overlay.id, live: true) { $0.rect.origin.y = value } }),
                    range: 0...1)
            seconds("Opacity", value: Binding(
                get: { overlay.opacity },
                set: { value in model.updateMedia(overlay.id, live: true) { $0.opacity = value } }),
                    range: 0.05...1)
            seconds("Rounded corners", value: Binding(
                get: { overlay.cornerRadiusFraction },
                set: { value in
                    model.updateMedia(overlay.id, live: true) { $0.cornerRadiusFraction = value }
                }),
                    range: 0...0.5)

            Button(role: .destructive) {
                model.removeMedia(overlay.id)
            } label: {
                Label("Remove This Picture", systemImage: "trash")
            }
        }
    }

    private func seconds(_ title: String, value: Binding<Double>,
                         range: ClosedRange<Double>) -> some View {
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

/// Text put on the video by hand.
///
/// **Every measurement is a fraction of the canvas**, so a title keeps its framing when the aspect
/// or the export size changes — the same reason the camera and the captions are written that way.
struct TextInspector: View {
    @ObservedObject var model: StudioDocumentModel

    private var selected: TextOverlay? {
        model.project.textOverlays.first { $0.id == model.selectedText }
            ?? model.project.textOverlays.first { $0.covers(model.sourceTime) }
    }

    var body: some View {
        Button {
            model.addTextAtPlayhead()
        } label: {
            Label("Add Text Here", systemImage: "textformat")
        }

        if model.project.textOverlays.isEmpty {
            Text("Text sits on top of everything, including the camera. Drag it on the canvas to "
                 + "move it.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let overlay = selected {
            SectionHeader("The Selected Line")
            TextField("Text", text: Binding(
                get: { overlay.text },
                set: { value in model.updateText(overlay.id) { $0.text = value } }),
                      axis: .vertical)
                .lineLimit(1...4)

            slider("Size", value: Binding(
                get: { overlay.sizeFraction },
                set: { value in model.updateTextLive(overlay.id) { $0.sizeFraction = value } }),
                   range: 0.02...0.18)

            slider("Width", value: Binding(
                get: { overlay.maxWidthFraction },
                set: { value in
                    model.updateTextLive(overlay.id) { $0.maxWidthFraction = value }
                }),
                   range: 0.2...1)

            slider("Fade", value: Binding(
                get: { overlay.fadeSeconds },
                set: { value in model.updateTextLive(overlay.id) { $0.fadeSeconds = value } }),
                   range: 0...1)

            Toggle("Bold", isOn: Binding(
                get: { overlay.isBold },
                set: { value in model.updateText(overlay.id) { $0.isBold = value } }))

            Picker("Typeface", selection: Binding(
                get: { overlay.typeface },
                set: { value in model.updateText(overlay.id) { $0.typeface = value } })) {
                Text("Rounded").tag(TextElement.Typeface.rounded)
                Text("System").tag(TextElement.Typeface.standard)
                Text("Monospaced").tag(TextElement.Typeface.monospaced)
            }

            // A box or a halo, not both: a halo exists for text that cannot wear a box, and
            // wearing both looks like a mistake.
            Toggle("Background box", isOn: Binding(
                get: { overlay.background != nil },
                set: { on in
                    model.updateText(overlay.id) {
                        $0.background = on ? RGBAColour(r: 0, g: 0, b: 0, a: 0.55) : nil
                        if on { $0.haloColour = nil }
                    }
                }))

            Toggle("Halo", isOn: Binding(
                get: { overlay.haloColour != nil },
                set: { on in
                    model.updateText(overlay.id) {
                        $0.haloColour = on ? RGBAColour(r: 0, g: 0, b: 0, a: 0.85) : nil
                        if on { $0.background = nil }
                    }
                }))

            Button(role: .destructive) {
                model.removeText(overlay.id)
            } label: {
                Label("Remove This Line", systemImage: "trash")
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }
}

/// The camera.
struct CameraInspector: View {
    @ObservedObject var model: StudioDocumentModel

    var body: some View {
        SectionHeader("Shape")
        Picker("Shape", selection: Binding(
            get: { model.project.camera.shape },
            set: { value in model.edit { $0.camera.shape = value } })) {
            ForEach(CameraSettings.Shape.allCases, id: \.self) { Text($0.title).tag($0) }
        }

        if model.project.camera.shape == .squircle {
            slider("Roundness", value: Binding(
                get: { model.project.camera.cornerRadiusFraction },
                set: { value in model.editLive { $0.camera.cornerRadiusFraction = value } }),
                   range: 0...0.5)
        }

        slider("Size", value: Binding(
            get: { model.project.camera.sizeFraction },
            set: { value in model.editLive { $0.camera.sizeFraction = value } }),
               range: 0.1...0.4)

        slider("Margin", value: Binding(
            get: { model.project.camera.marginFraction },
            set: { value in model.editLive { $0.camera.marginFraction = value } }),
               range: 0...0.1)

        SectionHeader("Corner")
        // Nine positions as a grid rather than a menu: where the camera goes is a spatial
        // question, and a list of nine phrases is a worse way to answer one.
        CornerGrid(selection: Binding(
            get: { model.project.camera.corner },
            set: { value in model.edit { $0.camera.corner = value } }))

        SectionHeader("Behaviour")
        Picker("While zoomed", selection: Binding(
            get: { model.project.camera.sizeDuringZoom },
            set: { value in model.edit { $0.camera.sizeDuringZoom = value } })) {
            ForEach(CameraSettings.ZoomSizing.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        // The default is the one people do not expect, so it says why.
        Text("A zoom exists to show something. The camera getting smaller keeps it out of the way.")
            .font(.system(size: Theme.Typography.caption))
            .foregroundStyle(.secondary)

        Toggle("Mirror", isOn: Binding(
            get: { model.project.camera.mirrored },
            set: { value in model.edit { $0.camera.mirrored = value } }))
        .toggleStyle(.switch).controlSize(.small)

        Toggle("Shadow", isOn: Binding(
            get: { model.project.camera.shadow != nil },
            set: { on in
                model.edit { $0.camera.shadow = on ? CaptureBackground.Shadow() : nil }
            }))
        .toggleStyle(.switch).controlSize(.small)

        slider("Fade in and out", value: Binding(
            get: { model.project.camera.fadeSeconds },
            set: { value in model.editLive { $0.camera.fadeSeconds = value } }),
               range: 0...2)

        SectionHeader("Layout over time")
        HStack {
            Button("Full frame here") { model.addCameraSegment(.fullFrame) }
            Button("Hide here") { model.addCameraSegment(.hidden) }
        }
        Text("A demo usually wants the camera full-frame for the intro and small for the rest.")
            .font(.system(size: Theme.Typography.caption))
            .foregroundStyle(.secondary)

        ForEach(model.project.cameraSegments) { segment in
            HStack {
                Text("\(segment.layout.title) · \(String(format: "%.1f", segment.start))s")
                    .font(.system(size: Theme.Typography.caption))
                Spacer()
                Button { model.removeCameraSegment(segment.id) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).clickableCursor()
                .accessibilityLabel("Remove this camera layout")
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
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

/// Nine positions, laid out where they mean.
struct CornerGrid: View {
    @Binding var selection: CaptureBackground.Alignment

    private let rows: [[CaptureBackground.Alignment]] = [
        [.topLeading, .top, .topTrailing],
        [.leading, .centre, .trailing],
        [.bottomLeading, .bottom, .bottomTrailing],
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(rows[row], id: \.self) { corner in
                        Button { selection = corner } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(selection == corner
                                      ? Color.accentColor.opacity(0.7)
                                      : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                                .frame(width: 26, height: 20)
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .accessibilityLabel(corner.rawValue)
                        .accessibilityAddTraits(selection == corner ? [.isSelected] : [])
                    }
                }
            }
        }
    }
}

/// Audio levels for whichever tracks the recording has.
struct AudioInspector: View {
    @ObservedObject var model: StudioDocumentModel

    private var hasMicrophone: Bool {
        FileManager.default.fileExists(atPath: model.bundle.microphoneURL.path)
    }

    private var hasSystemAudio: Bool {
        FileManager.default.fileExists(atPath: model.bundle.systemAudioURL.path)
    }

    var body: some View {
        SectionHeader("Audio")

        if !hasMicrophone && !hasSystemAudio {
            Text("This recording has no audio. Choose a microphone, or switch on system audio, "
                 + "before you record.")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
            return AnyView(EmptyView())
        }

        return AnyView(VStack(alignment: .leading, spacing: Theme.Space.md) {
            if hasMicrophone {
                // Two volumes, because "mute the video I was demonstrating but keep my narration"
                // is the common case and one number cannot say it.
                clipSlider("Narration", value: { $0.volume }, set: { $0.volume = $1 })
            }
            if hasSystemAudio {
                clipSlider("System audio", value: { $0.systemAudioVolume },
                           set: { $0.systemAudioVolume = $1 })
            }
            if hasMicrophone {
                Button("Remove silences") { model.removeSilencesFromMicrophone() }
                Text("Inserts real cuts you can undo — not a filter, so the timeline still shows "
                     + "exactly what will be exported.")
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        })
    }

    private func clipSlider(_ title: String,
                            value: @escaping (Clip) -> Double,
                            set: @escaping (inout Clip, Double) -> Void) -> some View {
        let current = model.project.timeline.clips.first.map(value) ?? 1
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { current },
                set: { level in
                    model.editLive { project in
                        for index in project.timeline.clips.indices {
                            set(&project.timeline.clips[index], level)
                        }
                    }
                }), in: 0...2) { editing in
                if editing { model.beginGesture() } else { model.endGesture() }
            }
        }
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
