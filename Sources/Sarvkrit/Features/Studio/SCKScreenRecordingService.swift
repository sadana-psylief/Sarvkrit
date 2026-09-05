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

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Recording")

    /// Nonisolated so `FeatureRegistry.makeAll()` — which is not on the main actor — can build the
    /// feature that owns it. Nothing here touches the main actor until a recording starts.
    override nonisolated init() { super.init() }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var bundle: RecordingBundle?
    private var manifest: RecordingManifest?
    private let events = EventRecorder()
    private var displayLink: CADisplayLink?

    /// The presentation timestamp of the first frame. Everything is measured from it, so the
    /// events and the picture cannot drift apart.
    private var firstFrame: CMTime?
    /// Accumulated across pauses, so the output has no gap and elapsed time means recorded time.
    private var pausedFor: CMTime = .zero
    private var pausedAt: CMTime?
    private var lastFrame: CMTime = .zero

    private(set) var isRecording = false
    private(set) var droppedFrames = 0
    private(set) var isPaused = false

    /// Maps a global AppKit point into the recording's pixel space. Nil means outside.
    private var mapPoint: ((CGPoint) -> CGPoint?)?

    var elapsed: TimeInterval {
        guard let firstFrame else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(lastFrame, firstFrame), pausedFor))
    }

    var recordsKeystrokes: Bool {
        get { events.recordsKeystrokes }
        set { events.recordsKeystrokes = newValue }
    }

    // MARK: - Start

    func start(_ request: RecordingRequest) async throws {
        guard !isRecording else { throw RecordingError.alreadyRecording }

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
        var manifest = RecordingManifest(source: request.source,
                                         pixelSize: pixels,
                                         pointPixelScale: CGFloat(filter.pointPixelScale),
                                         fps: request.fps)
        manifest.sourceRect = sourceRect.map(RectBox.init)
        manifest.displayID = geometry?.displayID
        manifest.hasSystemAudio = request.capturesSystemAudio
        manifest.accessibilityCursorScale = Self.accessibilityCursorScale()
        // Written before the first frame: a bundle still saying `recording` on next launch is one
        // the app died in the middle of, and that is the only signal a crash leaves.
        try bundle.write(manifest)

        try makeWriter(bundle: bundle, size: pixels)

        self.bundle = bundle
        self.manifest = manifest
        self.mapPoint = Self.mapper(sourceRect: sourceRect, geometry: geometry,
                                    scale: CGFloat(filter.pointPixelScale), pixels: pixels)
        events.begin(mapping: { [weak self] point in self?.mapPoint?(point) })

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "ai.psylief.sarvkrit.recording"))
        try await stream.startCapture()
        self.stream = stream
        isRecording = true
        droppedFrames = 0
        startCursorSampling()
        log.info("recording started \(configuration.width, privacy: .public)x\(configuration.height, privacy: .public)")
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

    private func makeWriter(bundle: RecordingBundle, size: CGSize) throws {
        guard let writer = try? AVAssetWriter(outputURL: bundle.screenURL, fileType: .mov) else {
            throw RecordingError.cannotWrite
        }
        // **Fragments, and this is what makes a crash survivable.** The writer flushes a
        // self-contained fragment every two seconds, so a file whose `finishWriting` never ran is
        // still playable up to the last one — rather than a header-less block nothing can open.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.9,
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.cannotWrite }
        writer.add(input)
        guard writer.startWriting() else { throw RecordingError.cannotWrite }

        self.writer = writer
        self.videoInput = input
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid else { return }
        // Idle frames say nothing changed. Not writing them is most of the difference between a
        // recording of a still screen being enormous and being small; the next real frame simply
        // carries a longer duration.
        guard Self.isComplete(buffer) else { return }
        MainActor.assumeIsolated { append(buffer) }
    }

    private nonisolated static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    private func append(_ buffer: CMSampleBuffer) {
        guard let writer, let videoInput, !isPaused else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)

        if firstFrame == nil {
            firstFrame = timestamp
            writer.startSession(atSourceTime: timestamp)
            // One clock. The events are anchored to the same instant the picture starts, which is
            // the whole reason the cursor lands on what it clicked.
            events.anchor(to: ProcessInfo.processInfo.systemUptime)
        }
        lastFrame = timestamp

        guard videoInput.isReadyForMoreMediaData else {
            // Dropped at the tail rather than blocking the stream. Counted, and reported when the
            // recording stops — a stuttering file produced silently is the failure to avoid.
            droppedFrames += 1
            return
        }
        if !videoInput.append(buffer) { droppedFrames += 1 }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        }
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
        guard isRecording, !isPaused else { return }
        isPaused = true
        pausedAt = lastFrame
        events.pause()
    }

    func resume() {
        guard isRecording, isPaused, let pausedAt else { return }
        isPaused = false
        // Rebased rather than left as a gap. A gap means every downstream time — zoom segments,
        // captions, the timeline — would have to know about it, and none of them should.
        pausedFor = CMTimeAdd(pausedFor, CMTimeSubtract(lastFrame, pausedAt))
        self.pausedAt = nil
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

        videoInput?.markAsFinished()
        await writer?.finishWriting()

        try? bundle.writeEvents(events.finish())
        if var manifest {
            manifest.state = .complete
            manifest.duration = elapsed
            manifest.droppedFrames = droppedFrames
            try? bundle.write(manifest)
        }

        writer = nil; videoInput = nil; self.bundle = nil; manifest = nil
        firstFrame = nil; pausedFor = .zero; pausedAt = nil; lastFrame = .zero
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
                               scale: CGFloat, pixels: CGSize) -> (CGPoint) -> CGPoint? {
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
