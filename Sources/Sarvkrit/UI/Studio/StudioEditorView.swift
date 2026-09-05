import AppKit
import SwiftUI

/// The editor window's contents: preview, rail, inspector, transport, timeline.
struct StudioEditorView: View {
    @ObservedObject var model: StudioDocumentModel
    @ObservedObject var player: StudioPlayer
    let onExport: () -> Void
    let onCancelExport: () -> Void
    let onPlayPause: () -> Void
    let onScrub: (TimeInterval) -> Void

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            HStack(spacing: 0) {
                PreviewHost(model: model, onScrub: onScrub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                rail
                Divider()
                inspector
                    .frame(width: 260)
            }
            Divider()
            transport
            Divider()
            TimelineHost(model: model, onScrub: onScrub)
                .frame(height: StudioTimelineView.preferredHeight)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Chrome

    private var titleBar: some View {
        HStack(spacing: Theme.Space.md) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).clickableCursor().disabled(!model.canUndo)
                .accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain).clickableCursor().disabled(!model.canRedo)
                .accessibilityLabel("Redo")

            Spacer()

            if let progress = model.exportProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: Theme.Typography.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                // A progress bar with no way to stop it is a hostage situation, and an export of a
                // long recording is exactly when somebody realises they picked the wrong preset.
                Button("Cancel", action: onCancelExport)
                    .accessibilityLabel("Cancel the export")
            }

            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.exportProgress != nil)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 44)
    }

    /// Tabs whose source the recording does not have are **disabled with a reason on hover**,
    /// never hidden. A control that vanishes teaches nothing.
    private var rail: some View {
        VStack(spacing: Theme.Space.xs) {
            ForEach(StudioDocumentModel.Inspector.allCases) { tab in
                Button { model.inspector = tab } label: {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: Theme.Metrics.tabIcon))
                        .frame(width: Theme.Metrics.tabSquare, height: Theme.Metrics.tabSquare)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Metrics.tabRadius,
                                             style: .continuous)
                                .fill(model.inspector == tab
                                      ? Color.accentColor.opacity(0.15) : .clear)
                        }
                        .foregroundStyle(model.inspector == tab ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .disabled(!isAvailable(tab))
                .help(isAvailable(tab) ? tab.title : "\(tab.title) — nothing was recorded for this")
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.inspector == tab ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.vertical, Theme.Space.sm)
        .padding(.horizontal, Theme.Space.xs)
    }

    private func isAvailable(_ tab: StudioDocumentModel.Inspector) -> Bool {
        switch tab {
        case .canvas, .cursor, .masks: return true
        case .camera, .audio: return true
        // Enabled whenever there is audio to work from — the tab is where you *make* captions,
        // so gating it on already having them would hide the only way to get any.
        case .captions:
            return FileManager.default.fileExists(atPath: model.bundle.microphoneURL.path)
                || !model.project.captions.isEmpty
        case .keystrokes: return !model.events.keys.isEmpty
        }
    }

    @ViewBuilder
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                switch model.inspector {
                case .canvas:
                    CanvasInspector(model: model)
                    DeviceFrameInspector(model: model)
                case .cursor: CursorInspector(model: model)
                case .masks: MaskInspector(model: model)
                case .camera: CameraInspector(model: model)
                case .captions: CaptionsInspector(model: model)
                case .keystrokes: KeystrokesInspector(model: model)
                case .audio: AudioInspector(model: model)
                }
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transport: some View {
        HStack(spacing: Theme.Space.lg) {
            Picker("", selection: Binding(
                get: { model.project.aspect },
                set: { value in model.edit { $0.aspect = value } })) {
                ForEach(AspectRatio.allCases) { ratio in
                    Text(ratio.title).tag(ratio)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Spacer()

            Button { model.step(seconds: -1) } label: { Image(systemName: "backward.end") }
                .buttonStyle(.plain).clickableCursor().accessibilityLabel("Back a second")
            Button(action: onPlayPause) {
                Image(systemName: player.isPlaying ? "pause.circle" : "play.circle")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain).clickableCursor()
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { model.step(seconds: 1) } label: { Image(systemName: "forward.end") }
                .buttonStyle(.plain).clickableCursor().accessibilityLabel("Forward a second")

            Spacer()

            Button { model.split() } label: { Image(systemName: "scissors") }
                .buttonStyle(.plain).clickableCursor().help("Split at the playhead (⌘B)")
                .accessibilityLabel("Split at the playhead")
            Button { model.addZoomAtPlayhead() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain).clickableCursor().help("Add a zoom here (Z)")
            .accessibilityLabel("Add a zoom at the playhead")

            Text(Self.clock(player.playhead) + " / " + Self.clock(model.duration))
                .font(.system(size: Theme.Typography.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 44)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Hosts

private struct PreviewHost: NSViewRepresentable {
    let model: StudioDocumentModel
    let onScrub: (TimeInterval) -> Void

    func makeNSView(context: Context) -> StudioPreviewView { StudioPreviewView(model: model) }
    func updateNSView(_ view: StudioPreviewView, context: Context) { view.needsDisplay = true }
}

private struct TimelineHost: NSViewRepresentable {
    let model: StudioDocumentModel
    let onScrub: (TimeInterval) -> Void

    func makeNSView(context: Context) -> StudioTimelineView {
        let view = StudioTimelineView(model: model)
        view.onScrub = onScrub
        return view
    }

    func updateNSView(_ view: StudioTimelineView, context: Context) { view.needsDisplay = true }
}
