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

        let size = NSSize(width: 660, height: 128)
        let frame = ScreenPlacement.screenUnderPointer()?.visibleFrame ?? .zero
        let panel = FloatingPanel(
            contentRect: NSRect(x: frame.midX - size.width / 2,
                                y: frame.minY + 80,
                                width: size.width, height: size.height),
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
            self?.previewFrame = image
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
        HStack(spacing: Theme.Space.lg) {
            source
            Divider().frame(height: 48)
            camera
            Divider().frame(height: 48)
            microphone
            Divider().frame(height: 48)
            options
            Spacer(minLength: 0)
            record
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 128)
        .background(.regularMaterial)
        .onExitCommand(perform: onCancel)
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionHeader("Record")
            Picker("", selection: Binding(
                get: { setup?.source ?? .display },
                set: { setup?.source = $0 })) {
                ForEach(RecordingSource.allCases) { source in
                    Label(source.title, systemImage: source.symbolName).tag(source)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
    }

    private var camera: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionHeader("Camera")
            HStack(spacing: Theme.Space.sm) {
                // **The reason this bar exists.** Seeing yourself before pressing Record is what
                // stops a ten-minute take of the ceiling.
                CameraThumbnail(image: model.previewFrame, isOn: setup?.cameraID != nil)
                Picker("", selection: Binding(
                    get: { setup?.cameraID ?? "" },
                    set: { id in
                        model.chooseCamera(model.cameras.first { $0.uniqueID == id })
                    })) {
                    Text("Off").tag("")
                    ForEach(model.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            if model.cameraDenied {
                deniedNote("Camera access is off.", requirement: .camera)
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            SectionHeader("Microphone")
            Picker("", selection: Binding(
                get: { setup?.microphoneID ?? "" },
                set: { id in
                    model.chooseMicrophone(model.microphones.first { $0.uniqueID == id })
                })) {
                Text("Off").tag("")
                ForEach(model.microphones, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }
            .labelsHidden()
            .frame(width: 150)
            if model.microphoneDenied {
                deniedNote("Microphone access is off.", requirement: .microphone)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Toggle("System audio", isOn: Binding(
                get: { setup?.capturesSystemAudio ?? false },
                set: { setup?.capturesSystemAudio = $0 }))
            .toggleStyle(.switch)
            .controlSize(.small)

            Picker("", selection: Binding(
                get: { setup?.countdownSeconds ?? 0 },
                set: { setup?.countdownSeconds = $0 })) {
                ForEach(RecordingSetup.countdownChoices, id: \.self) { seconds in
                    Text(seconds == 0 ? "No countdown" : "\(seconds)s").tag(seconds)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    private var record: some View {
        VStack(spacing: Theme.Space.xs) {
            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle")
                    .frame(width: 84)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)

            Text("⎋ to cancel")
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
        }
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
        .frame(maxWidth: 190, alignment: .leading)
    }
}

/// The little live square.
private struct CameraThumbnail: View {
    let image: CGImage?
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            .frame(width: 56, height: 56)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        // Mirrored, because a preview of yourself that is not is disorienting —
                        // it is the reflection people rehearse in.
                        .scaleEffect(x: -1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: isOn ? "video.slash" : "video")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(image == nil ? "No camera preview" : "Camera preview")
    }
}
