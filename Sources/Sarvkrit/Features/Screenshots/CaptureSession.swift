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
                            options: CaptureOptions,
                            chrome: CaptureOverlayController.Chrome
                                = CaptureOverlayController.Chrome()) async throws -> Result? {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        return await withCheckedContinuation { continuation in
            CaptureOverlayController.shared.present(frames: frames, chrome: chrome) { image, display, rect in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning:
                    Result(image: image, sourceRect: rect, display: display))
            }
        }
    }

    /// Freeze, let the user pick a window, then take a fresh capture of it.
    ///
    /// The second capture is not redundant. The frozen desktop has the window composited onto
    /// whatever is behind it, so a crop of it can never have a transparent background and can
    /// never drop the drop shadow. Those are both options here, so the result has to come from
    /// `SCContentFilter(desktopIndependentWindow:)`.
    static func captureWindow(using capturer: ScreenCapturing,
                              options: CaptureOptions) async throws -> Result? {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let windows = WindowPicker.capturable(
            from: try await capturer.shareableWindows(),
            excludingBundleIDs: options.excludedBundleIDs,
            desktopIconLayer: iconLayer)

        let picked: CapturableWindow? = await withCheckedContinuation { continuation in
            CaptureOverlayController.shared.presentWindowPicker(
                frames: frames, windows: windows) { continuation.resume(returning: $0) }
        }
        guard let picked else { return nil }

        let capture = try await capturer.captureWindow(picked, options: options)
        return Result(image: capture.image,
                      sourceRect: picked.frame,
                      display: frames.first { $0.geometry.frame.intersects(picked.frame) }?.geometry)
    }

    /// Runs a countdown, then captures.
    ///
    /// **The final capture is always live, even when Freeze is on.** A countdown over a bitmap
    /// taken *before* the countdown defeats the entire point of a self-timer — the seconds exist
    /// so the screen can be arranged, and freezing first would throw that arrangement away. So a
    /// timed area capture picks its rect against a frozen frame, waits, and then re-captures.
    static func timedCapture(_ mode: CaptureMode,
                             seconds: Int,
                             using capturer: ScreenCapturing,
                             options: CaptureOptions,
                             chrome: CaptureOverlayController.Chrome) async throws -> Result? {
        // Choose first, so the countdown is spent arranging rather than aiming.
        var chosenRect: CGRect?
        var chosenDisplay: DisplaySnapshotGeometry?
        if mode == .area {
            guard let picked = try await captureArea(using: capturer, options: options,
                                                     chrome: chrome) else { return nil }
            chosenRect = picked.sourceRect
            chosenDisplay = picked.display
        }

        await withCheckedContinuation { continuation in
            CountdownPresenter.shared.run(seconds: seconds) { _ in continuation.resume() }
        }

        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        if let chosenRect, let chosenDisplay,
           let frame = frames.first(where: { $0.geometry.displayID == chosenDisplay.displayID }) {
            let pixels = CaptureGeometry.pixelRect(forGlobalRect: chosenRect, in: frame.geometry)
            guard let cropped = frame.image.cropping(to: pixels.integral) else { return nil }
            return Result(image: cropped, sourceRect: chosenRect, display: frame.geometry)
        }

        let pointer = NSEvent.mouseLocation
        guard let frame = frames.first(where: { $0.geometry.frame.contains(pointer) })
                ?? frames.first
        else { throw CaptureError.noDisplays }
        return Result(image: frame.image, sourceRect: frame.geometry.frame, display: frame.geometry)
    }

    /// Pick a region, then capture it repeatedly while the user scrolls, and stitch.
    static func captureScrolling(using capturer: ScreenCapturing,
                                 options: CaptureOptions,
                                 chrome: CaptureOverlayController.Chrome) async throws -> Result? {
        guard let picked = try await captureArea(using: capturer, options: options,
                                                 chrome: chrome),
              let rect = picked.sourceRect, let display = picked.display else { return nil }

        let stitched: CGImage? = await withCheckedContinuation { continuation in
            ScrollCaptureSession.shared.start(region: rect, display: display,
                                              capturer: capturer, options: options) {
                continuation.resume(returning: $0)
            }
        }
        guard let stitched else { return nil }
        return Result(image: stitched, sourceRect: rect, display: display)
    }

    /// Pick a region and put its text on the pasteboard.
    ///
    /// Reuses the ordinary area overlay, so the aiming feels the same as any other capture; only
    /// what happens afterwards differs.
    static func recognizeText(using capturer: ScreenCapturing,
                              options: CaptureOptions,
                              chrome: CaptureOverlayController.Chrome) async throws -> Result? {
        try await captureArea(using: capturer, options: options, chrome: chrome)
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
