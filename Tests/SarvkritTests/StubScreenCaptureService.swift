import CoreGraphics
import Foundation
@testable import Sarvkrit

/// A `ScreenCapturing` that generates bitmaps instead of reading the screen.
///
/// The reason the protocol exists: `SarvkritTests` is hosted inside `Sarvkrit.app`, so a real SCK
/// call in a test would either prompt for Screen Recording — hanging the run — or return denied
/// results that make every assertion vacuous.
final class StubScreenCaptureService: ScreenCapturing {
    var displays: [DisplaySnapshotGeometry]
    var windows: [CapturableWindow]
    /// Set to make enumeration report nothing, which is what a denied grant looks like.
    var reportsNoDisplays = false
    private(set) var captureCount = 0
    private(set) var lastOptions: CaptureOptions?

    init(displays: [DisplaySnapshotGeometry] = [StubScreenCaptureService.defaultDisplay],
         windows: [CapturableWindow] = []) {
        self.displays = displays
        self.windows = windows
    }

    static let defaultDisplay = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        scale: 2, pixelSize: CGSize(width: 2880, height: 1800))

    func shareableDisplays() async throws -> [DisplaySnapshotGeometry] {
        reportsNoDisplays ? [] : displays
    }

    func shareableWindows() async throws -> [CapturableWindow] { windows }

    func snapshotAllDisplays(options: CaptureOptions) async throws -> [DisplayFrame] {
        guard !reportsNoDisplays else { throw CaptureError.noDisplays }
        lastOptions = options
        return try displays.map {
            captureCount += 1
            return DisplayFrame(geometry: $0, image: try Self.image(size: $0.pixelSize))
        }
    }

    func captureDisplay(_ display: DisplaySnapshotGeometry,
                        options: CaptureOptions) async throws -> CGImage {
        guard !reportsNoDisplays else { throw CaptureError.noDisplays }
        lastOptions = options
        captureCount += 1
        return try Self.image(size: display.pixelSize)
    }

    func captureWindow(_ window: CapturableWindow,
                       options: CaptureOptions) async throws -> WindowCapture {
        lastOptions = options
        captureCount += 1
        let scale: CGFloat = 2
        let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
        return WindowCapture(image: try Self.image(size: size),
                             contentRect: window.frame, scale: scale)
    }

    /// A flat grey bitmap of the requested pixel size. Content doesn't matter to any caller that
    /// uses this; the ones that care about pixels build their own.
    static func image(size: CGSize) throws -> CGImage {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = { () -> CGImage? in
                context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                return context.makeImage()
            }()
        else { throw CaptureError.noDisplays }
        return image
    }
}
