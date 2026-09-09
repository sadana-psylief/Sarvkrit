import Foundation

/// The one place calls into an `AVCaptureSession` are allowed to happen.
///
/// **This type exists because of a crash.** `AVCaptureSession.startRunning()` blocks until the
/// capture graph is up, and anything that needs a running session — `AVCaptureMovieFileOutput`'s
/// `startRecording(to:)` — blocks until it is. `CameraRecorder` handed the first to a detached
/// task and then made the second call on the main actor, so the main thread sat inside
/// AVFoundation waiting on work that had been given to a different thread.
///
/// That is worse than a stall. AVFoundation pumps the run loop while it waits, so AppKit went on
/// delivering events with a main-actor frame still on the stack. A click landing in that window
/// reached a global event monitor, `MainActor.assumeIsolated` asked the concurrency runtime which
/// executor was current, and the answer was the address `0x1e`. The app died there — eight seconds
/// after a recording that never started, because `SCStream` was three statements further on and
/// was never reached.
///
/// So: one serial queue, every call in the order it was asked for, none of them on the caller's
/// thread. `CameraPreviewSession` had the same unordered `Task.detached` pair and the same bug,
/// which is why this is a shared type rather than a fix in one file.
final class CaptureSessionRunner: @unchecked Sendable {

    private let queue: DispatchQueue

    init(label: String) {
        // Serial by default, and utility rather than default QoS: bringing a camera up is
        // background work that nothing on screen is waiting for.
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Runs `work` after everything already asked for, and never before this call returns.
    func submit(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}
