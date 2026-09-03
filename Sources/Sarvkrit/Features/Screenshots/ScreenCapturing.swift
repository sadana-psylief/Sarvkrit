import CoreGraphics
import Foundation

/// What a capture is allowed to include.
struct CaptureOptions: Equatable {
    /// The pointer. Always false for a freeze snapshot — the overlay draws its own crosshair, and
    /// a frozen cursor sitting under the live one looks like a rendering fault.
    var showsCursor = false
    /// Window mode only. Keeping the shadow changes the buffer size; see `CaptureConfigurationMath`.
    var includesShadow = true
    /// Window mode only: composite without the desktop behind, so the corners are transparent.
    var transparentBackground = false
    var hidesDesktopIcons = true
    /// Bundle ids to leave out. Ours is here by default, which is the single line that keeps the
    /// overlay, the Quick Access panels and pinned windows out of every capture.
    var excludedBundleIDs: Set<String> = [AppIdentity.bundleID]
}

/// A display plus the bitmap taken of it.
struct DisplayFrame {
    let geometry: DisplaySnapshotGeometry
    let image: CGImage
}

/// A captured window, with the geometry the capture actually used.
///
/// `contentRect` is carried because with shadows included it is *larger* than the window's frame,
/// and it is what the pixel size was derived from.
struct WindowCapture {
    let image: CGImage
    let contentRect: CGRect
    let scale: CGFloat
}

/// A window that can be captured.
struct CapturableWindow: Identifiable, Equatable {
    let id: CGWindowID
    /// Global AppKit points.
    let frame: CGRect
    let title: String?
    let owningBundleID: String?
    let owningAppName: String?
    let layer: Int
    let isOnScreen: Bool
}

/// How a capture was taken. Persisted in the history index, so the raw values are stable.
enum CaptureMode: String, Codable, CaseIterable, Equatable {
    case area
    case window
    case fullscreen
    case allDisplays
    case scrolling
    case textRecognition

    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Fullscreen"
        case .allDisplays: return "All Displays"
        case .scrolling: return "Scrolling"
        case .textRecognition: return "Text"
        }
    }

    var symbolName: String {
        switch self {
        case .area: return "selection.pin.in.out"
        case .window: return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        case .allDisplays: return "rectangle.on.rectangle"
        case .scrolling: return "arrow.down.doc"
        case .textRecognition: return "text.viewfinder"
        }
    }
}

/// Everything that talks to ScreenCaptureKit, behind one protocol.
///
/// **The point is the test bundle.** `SarvkritTests` is hosted inside `Sarvkrit.app`, so anything
/// that touches TCC during a test either prompts (and hangs the run) or returns denied results
/// that make assertions meaningless. Every SCK call in the app goes through here, and the tests
/// inject `StubScreenCaptureService` instead.
protocol ScreenCapturing: AnyObject {
    func shareableDisplays() async throws -> [DisplaySnapshotGeometry]
    func shareableWindows() async throws -> [CapturableWindow]
    /// One bitmap per display, taken as close to simultaneously as the framework allows. This is
    /// what Freeze Screen is built on.
    func snapshotAllDisplays(options: CaptureOptions) async throws -> [DisplayFrame]
    func captureDisplay(_ display: DisplaySnapshotGeometry,
                        options: CaptureOptions) async throws -> CGImage
    func captureWindow(_ window: CapturableWindow,
                       options: CaptureOptions) async throws -> WindowCapture
}

/// Why a capture didn't happen.
enum CaptureError: Error, Equatable {
    /// ScreenCaptureKit reported no displays. This is what denial looks like — there is no error
    /// to catch — so it is also the signal `ScreenRecordingRelaunch` reads.
    case noDisplays
    case displayGone
    case windowGone
    case cancelled
}
