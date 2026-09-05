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
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Recording")

    private var session: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?

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
    func start(device: AVCaptureDevice, microphone: AVCaptureDevice?,
               to url: URL, height: Int = 1080) throws {
        guard !isRecording else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = height >= 1080 ? .hd1920x1080 : .hd1280x720

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else { throw RecordingError.cannotWrite }
        session.addInput(videoInput)

        if let microphone, let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else { throw RecordingError.cannotWrite }
        session.addOutput(output)
        session.commitConfiguration()

        // Off the main thread: starting a capture session blocks for a noticeable moment, and
        // doing it on the main actor stalls the countdown the user is watching.
        Task.detached { session.startRunning() }

        try? FileManager.default.removeItem(at: url)
        output.startRecording(to: url, recordingDelegate: self)

        self.session = session
        self.movieOutput = output
        isRecording = true
    }

    func finish() {
        guard isRecording else { return }
        movieOutput?.stopRecording()
        isRecording = false
        let session = self.session
        Task.detached { session?.stopRunning() }
        self.session = nil
        movieOutput = nil
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            log.error("camera recording failed: \(error.localizedDescription, privacy: .public)")
        }
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
