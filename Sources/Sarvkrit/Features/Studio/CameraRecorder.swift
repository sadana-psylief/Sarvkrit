import AVFoundation
import Foundation
import os

/// Recording the camera alongside the screen.
///
/// Its own `AVCaptureSession` writing its own file, rather than a track muxed into the screen
/// recording. Separate because the editor has to be able to hide the camera for a stretch, change
/// its shape, or drop it entirely — none of which is possible once it has been composited in.
@MainActor
final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    /// Nonisolated: `os.Logger` is Sendable, and the delegate callback below arrives on
    /// AVFoundation's own queue.
    private nonisolated let log = Logger(subsystem: AppIdentity.logSubsystem,
                                         category: "Recording")

    private var session: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?

    /// A view of the session, for the on-screen preview.
    ///
    /// **Built during configuration, before the graph is running.** Creating it later — while the
    /// file output was already recording — adds a connection to a live session, which
    /// reconfigures it and stops the take: the camera file ended 1.2 seconds in with
    /// "Recording Stopped" and nothing said why. It is also deliberately a view of this session
    /// rather than a second `AVCaptureSession`, which is how the pre-record bar's preview and the
    /// recorder came to be fighting over one device.
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    /// Every blocking call into the capture graph goes through here, in order. The type's own
    /// documentation carries the crash that made it necessary.
    private let runner = CaptureSessionRunner(label: "ai.psylief.sarvkrit.camera")

    private(set) var isRecording = false

    /// Every camera on this Mac.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone],
                                         mediaType: .audio, position: .unspecified).devices
    }

    static func requestAccess(for media: AVMediaType) async -> Bool {
        await AVCaptureDevice.requestAccess(for: media)
    }

    /// - Parameter height: capped, because a 4K webcam feed for a 300-point circle is pure waste —
    ///   it costs encode time and disk for detail the canvas throws away.
    /// - Parameter device: nil records the microphone alone, which is what somebody who wants
    ///   narration without appearing on camera has asked for.
    func start(device: AVCaptureDevice?, microphone: AVCaptureDevice?,
               to url: URL, height: Int = 1080) throws {
        guard !isRecording, device != nil || microphone != nil else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if device != nil {
            session.sessionPreset = height >= 1080 ? .hd1920x1080 : .hd1280x720
        }

        if let device {
            let videoInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(videoInput) else { throw RecordingError.cannotWrite }
            session.addInput(videoInput)
        }

        if let microphone, let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { throw RecordingError.cannotWrite }
        session.addOutput(output)
        session.commitConfiguration()

        // Before anything starts running, for the reason on the property.
        if device != nil {
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            previewLayer = preview
        }

        self.session = session
        self.movieOutput = output
        isRecording = true

        // Building the graph above is cheap. These two calls are not: `startRunning()` blocks
        // until the graph is up, and `startRecording(to:)` blocks until the session is running.
        // They go one after the other on one thread, off the main actor — the previous version
        // detached the first and made the second here, and see `CaptureSessionRunner` for how
        // that ended.
        runner.submit {
            session.startRunning()
            try? FileManager.default.removeItem(at: url)
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    func finish() {
        guard isRecording else { return }
        isRecording = false
        let session = self.session
        let output = movieOutput
        self.session = nil
        movieOutput = nil
        previewLayer = nil
        // The same queue as `start`, so a stop can never overtake the start it is meant to end.
        runner.submit {
            output?.stopRecording()
            session?.stopRunning()
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        guard let error else { return }
        // Logged straight from AVFoundation's queue. Hopping to the main actor to write a line —
        // and asserting our way onto it — turned "the camera recording failed" into "the app
        // died", which is a strictly worse outcome for the same event.
        log.error("camera recording failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// Turning an audio file into the amplitude envelope the silence detector and the waveform both
/// read.
///
/// Pure arithmetic over decoded samples, kept here rather than inside `SilenceDetector` so that
/// detector stays free of AVFoundation and testable with an array of floats.
enum AudioEnvelope {

    /// - Parameter samplesPerSecond: the envelope's own resolution, not the audio's.
    static func read(url: URL, samplesPerSecond: Double = 100) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }

        let rate = try await track.load(.naturalTimeScale)
        let perSlice = max(1, Int(Double(rate) / samplesPerSecond))
        var envelope: [Float] = []
        var peak: Float = 0
        var counted = 0

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }

            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for index in 0..<(length / 4) {
                    peak = max(peak, abs(floats[index]))
                    counted += 1
                    if counted >= perSlice {
                        envelope.append(peak)
                        peak = 0
                        counted = 0
                    }
                }
            }
        }
        if counted > 0 { envelope.append(peak) }
        return envelope
    }
}
