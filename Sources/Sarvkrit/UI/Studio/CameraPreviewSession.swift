import AVFoundation
import AppKit
import CoreImage
import Foundation

/// A live camera feed, for looking at rather than recording.
///
/// Deliberately separate from `CameraRecorder`: this one never writes a file, runs only while the
/// pre-record bar is up, and is torn down the moment it closes. Sharing a session between "show me
/// myself" and "record me" would mean the preview holds the camera open after the bar has gone.
///
/// **Not main-actor, and that is deliberate.** `AVCaptureVideoDataOutput` delivers on its own
/// serial queue. An earlier version was main-actor and reached back with
/// `MainActor.assumeIsolated` to borrow its `CIContext` — which is an assertion, not a hop, and
/// trapped on the first frame. `CIContext` is documented thread-safe, so the right answer is to
/// render where the frame arrives and hop only to deliver the finished bitmap.
final class CameraPreviewSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {

    private let session = AVCaptureSession()
    private let renderer = PreviewFrameRenderer()
    private let onFrame: @Sendable (CGImage) -> Void

    init(device: AVCaptureDevice, onFrame: @escaping @Sendable (CGImage) -> Void) {
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
        output.setSampleBufferDelegate(
            self, queue: DispatchQueue(label: "ai.psylief.sarvkrit.preview"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // Off the main thread: starting a capture session blocks for a noticeable moment, and
        // doing it inline stalls the bar as it appears.
        let session = self.session
        Task.detached { session.startRunning() }
    }

    func stop() {
        let session = self.session
        Task.detached { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let image = renderer.image(from: sampleBuffer) else { return }
        // The one hop, and a real one: a finished bitmap handed to the main actor to display.
        let deliver = onFrame
        Task { @MainActor in deliver(image) }
    }
}

/// Turning a camera sample buffer into a bitmap, on whatever queue it arrived on.
///
/// Split out so the conversion can be exercised from a background queue in a test — which is the
/// thing that was never covered, and the reason the crash reached the user rather than CI.
/// `CIContext` is thread-safe; that is what makes this shape correct rather than merely convenient.
final class PreviewFrameRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func image(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        return image(from: buffer)
    }

    func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(image, from: image.extent)
    }
}
