import AppKit
import SwiftUI

/// What the export will be, before the save panel asks where to put it.
///
/// **There was no such thing.** Export went straight to a save panel whose message read
/// *"1080p H.264 — plays everywhere"* — a hardcoded string that was true only because one call
/// site passed `preset: .web`. A 3024×1964 recording came out at 1662×1080 and nothing in the app
/// offered any other answer.
struct ExportOptionsSheet: View {

    /// Everything the sheet needs to name real pixel sizes and a real file size.
    struct Subject {
        let canvas: CGSize
        /// The recording's own pixels, which are smaller than the canvas whenever the project has
        /// background padding.
        let recording: CGSize
        let seconds: TimeInterval
        let recordingFPS: Int
    }

    let subject: Subject
    let onCancel: () -> Void
    let onExport: (ExportPreset) -> Void

    /// Nil means Custom.
    @State private var presetID: String? = ExportPreset.web.id
    @State private var resolution: ExportResolution.Choice = .height(1080)
    @State private var codec: ExportPreset.Codec = .h264
    /// Nil follows the recording.
    @State private var fps: Int?

    private var resolutions: [ExportResolution] {
        ExportResolution.offered(forCanvas: subject.canvas)
    }

    private var chosen: ExportPreset {
        guard let presetID, let preset = ExportPreset.all.first(where: { $0.id == presetID }) else {
            var custom = ExportPreset(id: "custom", name: "Custom", purpose: "",
                                      codec: codec, height: nil, fps: fps)
            if case .height(let height) = resolution {
                custom.height = height
                custom.allowsUpscale = resolutions
                    .first { $0.resolution == resolution }?.upscales ?? false
            }
            return custom
        }
        return preset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("Export")
                .font(.system(size: Theme.Typography.title, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(ExportPreset.all) { preset in
                    presetRow(preset)
                }
                Divider()
                customRow
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .font(.system(size: Theme.Typography.body))
                    if let note = contentNote {
                        // Said, because the number in the menu is not the number the picture gets.
                        Text(note)
                            .font(.system(size: Theme.Typography.caption))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { onExport(chosen) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 460)
    }

    private func presetRow(_ preset: ExportPreset) -> some View {
        let size = preset.outputSize(forCanvas: subject.canvas)
        return Button {
            presetID = preset.id
        } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: presetID == preset.id
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(presetID == preset.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.system(size: Theme.Typography.body))
                    Text(preset.purpose)
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .font(.system(size: Theme.Typography.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Button {
                presetID = nil
            } label: {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: presetID == nil ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(presetID == nil ? Color.accentColor : .secondary)
                    Text("Custom").font(.system(size: Theme.Typography.body))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if presetID == nil {
                Picker("Resolution", selection: $resolution) {
                    ForEach(resolutions) { offered in
                        // The upscale is marked rather than hidden: 4K is offered because it was
                        // asked for, and because a 4K container is sometimes what a downstream
                        // tool needs.
                        Text(offered.upscales
                             ? "\(offered.name) — \(offered.pixels)  ⚠︎ upscaled"
                             : "\(offered.name) — \(offered.pixels)")
                            .tag(offered.resolution)
                    }
                }
                Picker("Format", selection: $codec) {
                    ForEach([ExportPreset.Codec.h264, .hevc, .proRes422], id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("Frame rate", selection: $fps) {
                    Text("Same as the recording (\(subject.recordingFPS) fps)")
                        .tag(Int?.none)
                    Text("60 fps").tag(Int?.some(60))
                    Text("30 fps").tag(Int?.some(30))
                }
                if let caveat = codec.caveat {
                    Label(caveat, systemImage: "exclamationmark.triangle")
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var summary: String {
        let size = chosen.outputSize(forCanvas: subject.canvas)
        let rate = chosen.frameRate(forRecording: subject.recordingFPS)
        let bytes = chosen.estimatedBytes(forCanvas: subject.canvas, seconds: subject.seconds,
                                          recordingFPS: subject.recordingFPS)
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return "\(Int(size.width)) × \(Int(size.height)) · \(chosen.codec.title) · \(rate) fps "
            + "· about \(formatter.string(fromByteCount: Int64(bytes)))"
    }

    /// **Padding costs resolution off the picture**, and only the dialog can say so: the height
    /// applies to the composited canvas, so a padded project puts the recording itself well below
    /// the number that was chosen. Silent when there is nothing worth mentioning.
    private var contentNote: String? {
        let size = chosen.outputSize(forCanvas: subject.canvas)
        guard subject.canvas.height > 0, subject.recording.height > 0 else { return nil }
        let content = (subject.recording.height * (size.height / subject.canvas.height)).rounded()
        guard content < size.height - 24 else { return nil }
        return "The background padding takes some of that — your recording lands "
            + "\(Int(content)) pixels tall."
    }
}
