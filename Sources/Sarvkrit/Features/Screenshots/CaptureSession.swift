import AppKit
import CoreGraphics
import Foundation

/// One capture, from trigger to finished image.
///
/// Sits between the feature (which knows about settings and hotkeys) and the overlay (which knows
/// about panels), so neither has to know about the other. The async boundary is here because
/// ScreenCaptureKit is async and the overlay is a callback.
@MainActor
enum CaptureSession {

    /// What a finished capture produced.
    struct Result {
        let image: CGImage
        let sourceRect: CGRect?
        let display: DisplaySnapshotGeometry?
    }

    /// Freeze every display, let the user pick an area, hand back the crop.
    ///
    /// Returns nil when the user cancelled — which is an ordinary outcome, not an error, and must
    /// not produce a "couldn't take a screenshot" toast.
    static func captureArea(using capturer: ScreenCapturing,
                            options: CaptureOptions) async throws -> Result? {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        return await withCheckedContinuation { continuation in
            CaptureOverlayController.shared.present(frames: frames) { image, display, rect in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning:
                    Result(image: image, sourceRect: rect, display: display))
            }
        }
    }

    /// The display under the pointer, whole.
    ///
    /// Not `NSScreen.main` and not the first display: the first is whichever has the menu bar,
    /// which on a multi-display Mac is rarely the one being looked at.
    static func captureFullscreen(using capturer: ScreenCapturing,
                                  options: CaptureOptions) async throws -> Result {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        let pointer = NSEvent.mouseLocation
        guard let frame = frames.first(where: { $0.geometry.frame.contains(pointer) })
                ?? frames.first
        else { throw CaptureError.noDisplays }
        return Result(image: frame.image, sourceRect: frame.geometry.frame, display: frame.geometry)
    }
}
