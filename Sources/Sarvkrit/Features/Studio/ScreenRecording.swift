import CoreGraphics
import Foundation

/// What a recording was asked for.
struct RecordingRequest: Equatable {
    var source: RecordingSource
    /// Area mode: the chosen rectangle in global AppKit points.
    var areaRect: CGRect?
    var display: DisplaySnapshotGeometry?
    var window: CapturableWindow?
    var fps: Int = 60
    var capturesSystemAudio = false
    var hidesDesktopIcons = true
    var destination: URL

    init(source: RecordingSource, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

/// Why a recording did not happen, or stopped.
///
/// `noDisplays` is the same signal `CaptureError` carries and means the same thing: **that is what
/// a denied Screen Recording grant looks like.** There is no error to catch — ScreenCaptureKit
/// simply reports nothing to record — so `ScreenRecordingRelaunch` reads it here too.
enum RecordingError: Error, Equatable {
    case noDisplays
    case displayGone
    case windowGone
    case cannotWrite
    case alreadyRecording
    case outOfSpace(freeBytes: Int64)
    case cancelled
}

/// Everything that streams from ScreenCaptureKit, behind one protocol.
///
/// **Sibling of `ScreenCapturing`, and for exactly the same reason.** `SarvkritTests` is hosted
/// inside `Sarvkrit.app`, so a live `SCStream` in a test either prompts for TCC — hanging the run
/// — or returns denied results that make every assertion vacuous. Kept separate from
/// `ScreenCapturing` rather than bolted onto it because every method there returns a finished
/// `CGImage`, and a frame pump is a different shape: adding one would also break
/// `StubScreenCaptureService` at compile time for no gain.
@MainActor
protocol ScreenRecording: AnyObject {
    var isRecording: Bool { get }
    /// Reports elapsed *recorded* time — which is not wall-clock once a recording has been paused.
    var elapsed: TimeInterval { get }
    var droppedFrames: Int { get }

    /// - Parameter setup: the camera and microphone the user chose in the pre-record bar, if any.
    func start(_ request: RecordingRequest, setup: RecordingSetup?) async throws
    func pause()
    func resume()
    /// - Returns: the finished bundle, or nil if nothing usable was written.
    func finish() async throws -> RecordingBundle?
    /// Stops and deletes. For "that take was rubbish, go again".
    func discard() async
}
