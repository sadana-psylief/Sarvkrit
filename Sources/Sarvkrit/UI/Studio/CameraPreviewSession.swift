import AVFoundation
import AppKit
import CoreImage
import Foundation

/// A live camera feed, for looking at rather than recording.
///
/// Deliberately separate from `CameraRecorder`: this one never writes a file, runs only while the
/// pre-record bar is up, and is torn down the moment it closes. Sharing a session between "show me
/// myself" and "record me" would mean the preview holds the camera open after the bar has gone.
@MainActor
final class CameraPreviewSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let onFrame: (CGImage?) -> Void

    init(device: AVCaptureDevice, onFrame: @escaping (CGImage?) -> Void) {
        self.onFrame = onFrame
        super.init()

        session.beginConfiguration()
        // The preview is a 56-point square; anything above this is decoded and thrown away.
        session.sessionPreset = .low
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ai.psylief.sarvkrit.preview"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // Off the main thread: starting a capture session blocks for a noticeable moment, and
        // doing it inline stalls the bar as it appears.
        Task.detached { [session] in session.startRunning() }
    }

    func stop() {
        let session = self.session
        Task.detached { session.stopRunning() }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        // Rendered here, on the capture queue, so the main thread only ever receives a finished
        // bitmap — the same reason the recorder does its writing off the main actor.
        guard let rendered = MainActor.assumeIsolated({ context })
            .createCGImage(image, from: image.extent) else { return }
        Task { @MainActor in self.onFrame(rendered) }
    }
}
