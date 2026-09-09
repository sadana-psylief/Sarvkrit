import AVFoundation
import AppKit
import SwiftUI

/// The bar that appears before a recording starts.
///
/// **This is the feature's front door, and it was missing.** Without it ⌃⇧R could only ever record
/// the whole display with no camera, no microphone and no countdown — every one of those choices
/// existed in the model and none of them was reachable.
///
/// The live camera preview is the point of the whole surface. Discovering that the camera was off,
/// or pointed at the ceiling, *after* a ten-minute take is the most expensive failure this feature
/// has; seeing yourself before you press Record costs nothing and prevents all of it.
///
/// Registered with `CaptureOverlayGuard`, like every other floating thing: ⌃⇧⎋ is documented as
/// always clearing the screen and this must not be the exception that makes that untrue.
@MainActor
final class PreRecordBarController {
    static let shared = PreRecordBarController()

    private var panel: FloatingPanel?
    private let model = PreRecordModel()

    var isShowing: Bool { panel != nil }

    /// Called when the user presses Record, with everything they chose.
    var onRecord: ((RecordingSetup) -> Void)?

    func show(setup: RecordingSetup) {
        dismiss()
        model.setup = setup
        model.refreshDevices()
        model.startPreview()

        let frame = ScreenPlacement.screenUnderPointer()?.visibleFrame ?? .zero
        let panel = FloatingPanel(
            contentRect: NSRect(x: frame.midX - 330, y: frame.minY + 80,
                                width: 660, height: 64),
            // Key, so Escape works without clicking first.
            style: .init(level: .modalPanel, acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true))
        panel.contentView = NSHostingView(rootView: PreRecordBarView(
            model: model,
            onRecord: { [weak self] in
                guard let self, let setup = self.model.setup else { return }
                self.dismiss()
                self.onRecord?(setup)
            },
            onCancel: { [weak self] in self?.dismiss() }))
        // Sized to its contents rather than to a number picked in advance. The rounded corners
        // would otherwise be clipped by a panel still the shape of the old slab, and the row's
        // width now depends on how long the device names are.
        if let fitting = panel.contentView?.fittingSize {
            panel.setContentSize(fitting)
            panel.setFrameOrigin(NSPoint(x: frame.midX - fitting.width / 2,
                                         y: frame.minY + 80))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel
    }

    func dismiss() {
        model.stopPreview()
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The bar's live state: which devices exist, and what the camera currently sees.
@MainActor
final class PreRecordModel: ObservableObject {
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    /// The most recent camera frame, so the user can see themselves before committing.
    @Published var previewFrame: CGImage?
    @Published var micLevel: Float = 0
    @Published var cameraDenied = false
    @Published var microphoneDenied = false

    var setup: RecordingSetup?

    private var preview: CameraPreviewSession?

    func refreshDevices() {
        cameras = CameraRecorder.devices()
        microphones = CameraRecorder.microphones()
        setup?.reconcile(cameraIDs: cameras.map(\.uniqueID),
                         microphoneIDs: microphones.map(\.uniqueID))
        cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied
        microphoneDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        // Re-read every time the bar appears, so granting the permission in System Settings and
        // coming back shows the camera rather than the stale refusal.
    }

    func startPreview() {
        stopPreview()
        guard let id = setup?.cameraID,
              let device = cameras.first(where: { $0.uniqueID == id }) else { return }
        preview = CameraPreviewSession(device: device) { [weak self] image in
            Task { @MainActor in self?.previewFrame = image }
        }
    }

    func stopPreview() {
        preview?.stop()
        preview = nil
        previewFrame = nil
    }

    /// Asks for the grant, then starts the preview — so choosing a camera *shows* you the camera
    /// rather than silently doing nothing until the next launch.
    func chooseCamera(_ device: AVCaptureDevice?) {
        setup?.cameraID = device?.uniqueID
        guard device != nil else { return stopPreview() }
        Task {
            _ = await CameraRecorder.requestAccess(for: .video)
            refreshDevices()
            startPreview()
        }
    }

    func chooseMicrophone(_ device: AVCaptureDevice?) {
        setup?.microphoneID = device?.uniqueID
        guard device != nil else { return }
        Task {
            _ = await CameraRecorder.requestAccess(for: .audio)
            refreshDevices()
        }
    }
}

private struct PreRecordBarView: View {
    @ObservedObject var model: PreRecordModel
    let onRecord: () -> Void
    let onCancel: () -> Void

    private var setup: RecordingSetup? { model.setup }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.md) {
                source
                Divider().frame(height: 22)
                camera
                microphone
                options
                Divider().frame(height: 22)
                record
                close
            }
            // A second line only when there is something wrong to say. The compact row is the
            // normal case; a refused grant is not, and it gets said in words rather than reduced
            // to an icon — a control that reports a problem it will not help you fix is the
            // failure the README names.
            if model.cameraDenied {
                deniedNote("Camera access is off.", requirement: .camera)
            }
            if model.microphoneDenied {
                deniedNote("Microphone access is off.", requirement: .microphone)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        // Shaped the way the app's own toast is shaped. This used to end in a bare
        // `.background(.regularMaterial)` with no shape, which on a borderless
        // clear-backgrounded panel fills a hard-edged rectangle.
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card + 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 6, style: .continuous)
            .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .onExitCommand(perform: onCancel)
    }

    /// Icons rather than words, with the words in the tooltips: three segments carrying "Display",
    /// "Window" and "Area" cost 210pt of a row that has to fit on a laptop screen.
    private var source: some View {
        Picker("", selection: Binding(
            get: { setup?.source ?? .display },
            set: { setup?.source = $0 })) {
            ForEach(RecordingSource.allCases) { source in
                Image(systemName: source.symbolName)
                    .help(source.title)
                    .accessibilityLabel(source.title)
                    .tag(source)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    private var camera: some View {
        HStack(spacing: Theme.Space.sm) {
            // **The reason this bar exists.** Seeing yourself before pressing Record is what
            // stops a ten-minute take of the ceiling. Kept at full size while everything around
            // it shrank, because it is the only thing here that cannot be read from a label.
            CameraThumbnail(image: model.previewFrame, isOn: setup?.cameraID != nil)
            Picker("", selection: Binding(
                get: { setup?.cameraID ?? "" },
                set: { id in
                    model.chooseCamera(model.cameras.first { $0.uniqueID == id })
                })) {
                Label("No camera", systemImage: "video.slash").tag("")
                ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .labelsHidden()
            .frame(width: 130)
            .help("Camera")
        }
    }

    private var microphone: some View {
        Picker("", selection: Binding(
            get: { setup?.microphoneID ?? "" },
            set: { id in
                model.chooseMicrophone(model.microphones.first { $0.uniqueID == id })
            })) {
            Label("No microphone", systemImage: "mic.slash").tag("")
            ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
        }
        .labelsHidden()
        .frame(width: 130)
        .help("Microphone")
    }

    /// The two settings that are set once and then left alone, behind a menu.
    ///
    /// **Not hidden — deferred.** Both are remembered between launches, so they are a decision
    /// somebody makes on their first recording and never revisits, while the camera and the
    /// microphone are checked before every single take. Ranking them equally in one row is what
    /// made the bar feel like a form.
    private var options: some View {
        Menu {
            Toggle("Record system audio", isOn: Binding(
                get: { setup?.capturesSystemAudio ?? false },
                set: { setup?.capturesSystemAudio = $0 }))

            Picker("Countdown", selection: Binding(
                get: { setup?.countdownSeconds ?? 0 },
                set: { setup?.countdownSeconds = $0 })) {
                ForEach(RecordingSetup.countdownChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "None" : "\(seconds) seconds").tag(seconds)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("System audio and countdown")
    }

    private var record: some View {
        Button(action: onRecord) {
            Label("Record", systemImage: "record.circle")
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .fixedSize()
    }

    /// **A way out you can see.**
    ///
    /// Escape already worked, twice over — `onExitCommand` here and `CaptureOverlayGuard`'s own
    /// monitor. But the only thing that said so was one line of caption-sized secondary text on a
    /// panel with no title bar and no window controls, and "I cannot close it until I record
    /// something" is what that looks like from the outside. The hint stays, in the tooltip.
    private var close: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .clickableCursor()
        .help("Cancel (⎋)")
        .accessibilityLabel("Cancel")
    }

    /// **A refusal with a way out of it.** Saying "check System Settings" and stopping there is
    /// the failure the README names: a control that reports a problem it will not help you fix.
    /// `Requirement` already knows which pane each grant lives in.
    private func deniedNote(_ text: String, requirement: Requirement) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.orange)
            Button("Open Settings") {
                NSWorkspace.shared.open(requirement.settingsURL)
            }
            .buttonStyle(.link)
            .font(.system(size: Theme.Typography.caption))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The little live square.
private struct CameraThumbnail: View {
    let image: CGImage?
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            .frame(width: 34, height: 34)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        // Mirrored, because a preview of yourself that is not is disorienting —
                        // it is the reflection people rehearse in.
                        .scaleEffect(x: -1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                } else {
                    Image(systemName: isOn ? "video.slash" : "video")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(image == nil ? "No camera preview" : "Camera preview")
    }
}
