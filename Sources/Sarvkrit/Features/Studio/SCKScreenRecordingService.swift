import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// The only file in the app that streams from ScreenCaptureKit.
///
/// **`SCRecordingOutput` is macOS 15 and the deployment target is 14.4**, which `project.yml`
/// explains cannot move — Core Audio process taps, which the volume mixer needs, do not exist
/// before 14.4. So frames are pumped by hand into an `AVAssetWriter`. That is not a hardship: the
/// one-line API writes a single muxed file, and separate tracks are wanted anyway so audio can be
/// edited without touching the picture.
@MainActor
final class SCKScreenRecordingService: NSObject, ScreenRecording, SCStreamOutput, SCStreamDelegate {

    /// Nonisolated: ScreenCaptureKit's delegate callbacks arrive on its own queue, and
    /// `os.Logger` is Sendable.
    private nonisolated let log = Logger(subsystem: AppIdentity.logSubsystem,
                                         category: "Recording")

    /// Nonisolated so `FeatureRegistry.makeAll()` — which is not on the main actor — can build the
    /// feature that owns it. Nothing here touches the main actor until a recording starts.
    override nonisolated init() { super.init() }

    private var stream: SCStream?
    /// Not main-actor: `SCStream` hands frames to its own queue and this is written from there.
    /// See `RecordingWriter` for the crash that made this explicit.
    private nonisolated(unsafe) var writer: RecordingWriter?
    private var bundle: RecordingBundle?
    private var manifest: RecordingManifest?
    private let events = EventRecorder()
    private let camera = CameraRecorder()
    private var displayLink: CADisplayLink?

    private(set) var isRecording = false
    /// True from the moment `start` is entered until it has either succeeded or cleaned up.
    /// `isRecording` is only set once the stream is live, and there are two `await`s before that,
    /// so without this a second ⌃⇧R during a start walked straight past the guard.
    private var isStarting = false

    /// Maps a global AppKit point into the recording's pixel space. Nil means outside.
    private var mapPoint: (@Sendable (CGPoint) -> CGPoint?)?

    var elapsed: TimeInterval { writer?.elapsed ?? 0 }
    var droppedFrames: Int { writer?.droppedFrames ?? 0 }
    var isPaused: Bool { writer?.isPaused ?? false }

    var recordsKeystrokes: Bool {
        get { events.recordsKeystrokes }
        set { events.recordsKeystrokes = newValue }
    }

    // MARK: - Start

    /// - Parameter setup: the camera and microphone the user chose, if any.
    func start(_ request: RecordingRequest, setup: RecordingSetup? = nil) async throws {
        guard !isRecording, !isStarting else { throw RecordingError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }

        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        // Denial has no error to catch — ScreenCaptureKit simply reports nothing. This is the same
        // signal `CaptureError.noDisplays` carries, and `ScreenRecordingRelaunch` reads it.
        guard !content.displays.isEmpty else { throw RecordingError.noDisplays }

        let (filter, sourceRect, geometry) = try makeFilter(request, content: content)
        let configuration = makeConfiguration(request, filter: filter, sourceRect: sourceRect)

        let pixels = CGSize(width: configuration.width, height: configuration.height)
        try checkSpace(for: pixels, fps: request.fps)

        let bundle = try RecordingBundle.create(at: request.destination)
        do {
            var manifest = RecordingManifest(source: request.source,
                                             pixelSize: pixels,
                                             pointPixelScale: CGFloat(filter.pointPixelScale),
                                             fps: request.fps)
            manifest.sourceRect = sourceRect.map(RectBox.init)
            manifest.displayID = geometry?.displayID
            manifest.hasSystemAudio = request.capturesSystemAudio
            manifest.accessibilityCursorScale = Self.accessibilityCursorScale()
            // Written before the first frame: a bundle still saying `recording` on next launch
            // is one the app died in the middle of, the only signal a crash leaves.
            try bundle.write(manifest)

            writer = try RecordingWriter(url: bundle.screenURL, size: pixels, fps: request.fps)

            self.bundle = bundle
            // Handed to the recorder by value. It used to reach back through `self?.mapPoint`,
            // meaning a nonisolated monitor callback read a main-actor property; the mapper is a
            // pure function of the geometry, so there is nothing to reach back for.
            let mapper = Self.mapper(sourceRect: sourceRect, geometry: geometry,
                                     scale: CGFloat(filter.pointPixelScale), pixels: pixels)
            self.mapPoint = mapper

            // Started before the stream, so the camera is already rolling when the first screen
            // frame lands rather than a second behind it.
            if let setup {
                let device = setup.cameraID.flatMap { id in
                    CameraRecorder.devices().first { $0.uniqueID == id }
                }
                let microphone = setup.microphoneID.flatMap { id in
                    CameraRecorder.microphones().first { $0.uniqueID == id }
                }
                // **A microphone with no camera still has to be recorded.** Gating this on the
                // camera meant choosing a mic alone captured nothing at all, silently — the worst
                // possible way for narration to go missing.
                if device != nil || microphone != nil {
                    try? camera.start(device: device, microphone: microphone,
                                      to: device != nil ? bundle.cameraURL : bundle.microphoneURL)
                    manifest.hasCamera = device != nil
                    manifest.hasMicrophone = microphone != nil
                    try? bundle.write(manifest)
                }
            }
            // Assigned after the camera block, not before: the block mutates a local copy, so the
            // old order wrote `hasCamera` to disk and kept a stale value in memory.
            self.manifest = manifest

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            let frames = DispatchQueue(label: "ai.psylief.sarvkrit.recording")
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames)
            try await stream.startCapture()
            self.stream = stream
            isRecording = true
            // Monitors last. Nothing before this point produces an event worth recording, and a
            // start that failed part-way used to leave them installed for the life of the process
            // — the app then watched every click on the Mac with no recording running.
            events.begin(mapping: mapper)
            startCursorSampling()
            let size = "\(configuration.width)x\(configuration.height)"
            log.info("recording started \(size, privacy: .public)")
        } catch {
            // A start that fails leaves nothing behind. It used to leave the camera running, the
            // event monitors installed for the rest of the process, and a bundle still saying
            // `state: "recording"` that the next launch offered to recover as a crashed take.
            log.error("recording failed to start: \(error.localizedDescription, privacy: .public)")
            camera.finish()
            _ = events.finish(anchoredTo: nil)
            writer = nil
            stream = nil
            self.bundle = nil
            self.manifest = nil
            mapPoint = nil
            try? FileManager.default.removeItem(at: bundle.root)
            throw error
        }
    }

    // MARK: - Filter and configuration

    private func makeFilter(_ request: RecordingRequest, content: SCShareableContent)
        throws -> (SCContentFilter, CGRect?, DisplaySnapshotGeometry?) {
        switch request.source {
        case .window:
            guard let wanted = request.window,
                  let window = content.windows.first(where: { $0.windowID == wanted.id }) else {
                throw RecordingError.windowGone
            }
            return (SCContentFilter(desktopIndependentWindow: window), nil, nil)

        case .display, .area:
            guard let geometry = request.display
                ?? content.displays.first.map({ DisplaySnapshotGeometry(
                    displayID: $0.displayID,
                    frame: CGRect(x: 0, y: 0, width: CGFloat($0.width), height: CGFloat($0.height)),
                    scale: 2,
                    pixelSize: CGSize(width: $0.width * 2, height: $0.height * 2)) }),
                let display = content.displays.first(where: { $0.displayID == geometry.displayID })
            else { throw RecordingError.displayGone }

            // Our own windows never appear in a recording. The same one line that keeps the
            // capture overlay out of every screenshot.
            let excluded = content.applications.filter {
                $0.bundleIdentifier == AppIdentity.bundleID
            }
            let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
            let exceptions = request.hidesDesktopIcons
                ? content.windows.filter { $0.windowLayer == iconLayer } : []
            let filter = SCContentFilter(display: display, excludingApplications: excluded,
                                         exceptingWindows: exceptions)
            return (filter, request.source == .area ? request.areaRect : nil, geometry)
        }
    }

    private func makeConfiguration(_ request: RecordingRequest, filter: SCContentFilter,
                                   sourceRect: CGRect?) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let rect = sourceRect ?? filter.contentRect
        let size = RecordingGeometry.pixelSize(contentRect: rect, pointPixelScale: scale)
        configuration.width = size.width
        configuration.height = size.height

        if let sourceRect {
            // Points, relative to the display's own origin.
            configuration.sourceRect = sourceRect
        }

        // **False, and this is the feature.** The pointer is logged instead and redrawn at
        // composite time, which is what lets it stay sharp at 2.5x and carry motion blur.
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(request.fps))
        // 5 is the floor SCK documents for smooth capture; 8 leaves headroom on a busy machine.
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Same forced sRGB as the screenshot path, for the same reason: an extended-range buffer
        // written out without conversion comes back visibly washed out.
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = request.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if #available(macOS 14.2, *) { configuration.includeChildWindows = true }
        return configuration
    }

    // MARK: - Writing

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid else { return }
        // Idle frames say nothing changed. Not writing them is most of the difference between a
        // recording of a still screen being enormous and being small; the next real frame simply
        // carries a longer duration.
        guard Self.isComplete(buffer) else { return }
        // Straight to the writer, on this queue. **No hop to the main actor**: the previous version
        // asserted its way onto it with `MainActor.assumeIsolated` and trapped on the first frame.
        writer?.append(buffer)
    }

    private nonisolated static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Same trap as the frame handler had, on the path that runs when a display is unplugged
        // mid-recording — so the error that should have ended the take cleanly ended the app.
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Cursor sampling

    private func startCursorSampling() {
        // The display's own refresh rate, via NSScreen (macOS 14+). CVDisplayLink is deprecated
        // from 15 and this is the supported replacement at our target.
        let screen = ScreenPlacement.screenUnderPointer() ?? NSScreen.main
        displayLink = screen?.displayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func tick() { events.sampleCursor() }

    // MARK: - Pause, finish, discard

    func pause() {
        guard isRecording else { return }
        writer?.pause()
        events.pause()
    }

    func resume() {
        guard isRecording else { return }
        writer?.resume()
        events.resume()
    }

    func flag() { events.flag() }

    func finish() async throws -> RecordingBundle? {
        guard isRecording, let bundle else { return nil }
        isRecording = false
        displayLink?.invalidate()
        displayLink = nil
        try? await stream?.stopCapture()
        stream = nil
        camera.finish()

        let anchor = writer?.firstFrameHostTime
        let duration = elapsed
        let dropped = droppedFrames
        await writer?.finish()

        try? bundle.writeEvents(events.finish(anchoredTo: anchor))
        if var manifest {
            manifest.state = .complete
            manifest.duration = duration
            manifest.droppedFrames = dropped
            try? bundle.write(manifest)
        }

        writer = nil
        self.bundle = nil
        manifest = nil
        return bundle
    }

    func discard() async {
        let doomed = bundle
        _ = try? await finish()
        if let doomed { try? FileManager.default.removeItem(at: doomed.root) }
    }

    // MARK: - Space and scale

    /// Refuses to start with under two minutes of room, and says the number.
    private func checkSpace(for size: CGSize, fps: Int) throws {
        let values = try? RecordingBundle.defaultDirectory()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        let perSecond = Int64(size.width * size.height) / 8
        guard free > perSecond * Int64(fps > 30 ? 120 : 90) else {
            throw RecordingError.outOfSpace(freeBytes: free)
        }
    }

    /// The user's Accessibility pointer size. Stored, not applied — see `RecordingManifest`.
    private static func accessibilityCursorScale() -> Double {
        UserDefaults(suiteName: "com.apple.universalaccess")?
            .object(forKey: "mouseDriverCursorSize") as? Double ?? 1
    }

    // MARK: - Mapping

    /// Global AppKit points to the recording's own pixel space, or nil when outside it.
    ///
    /// Nil is the answer that matters: in area and window modes the pointer spends much of its time
    /// outside the frame, and a cursor pinned to the edge looks like a bug.
    private static func mapper(sourceRect: CGRect?, geometry: DisplaySnapshotGeometry?,
                               scale: CGFloat, pixels: CGSize) -> @Sendable (CGPoint) -> CGPoint? {
        return { global in
            guard let geometry else {
                // Window mode: the per-frame geometry sidecar is what resolves this properly, and
                // until that lands a window recording simply has no cursor rather than a wrong one.
                return nil
            }
            let local = CGPoint(x: global.x - geometry.frame.minX,
                                y: geometry.frame.maxY - global.y)
            let origin = sourceRect.map { CGPoint(x: $0.minX, y: $0.minY) } ?? .zero
            let point = CGPoint(x: (local.x - origin.x) * scale, y: (local.y - origin.y) * scale)
            guard point.x >= 0, point.y >= 0,
                  point.x < pixels.width, point.y < pixels.height else { return nil }
            return point
        }
    }
}
