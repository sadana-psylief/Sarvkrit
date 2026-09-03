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

    /// Captures a rect given up front, with no overlay at all.
    ///
    /// What `sarvkrit://capture-area?x=…&y=…&width=…&height=…` runs, and the reference has the
    /// same parameters. A script that already knows where to look should not have to put a
    /// full-screen overlay in front of somebody to say so.
    ///
    /// **Deliberately the same crop a drag produces** — `CaptureGeometry.pixelRect` against the
    /// display's own geometry — rather than a second path that could disagree with it about
    /// scale or about which way `y` runs.
    ///
    /// - Parameter rect: global AppKit points, bottom-left origin, like every other rect here.
    static func captureRect(_ rect: CGRect, displayIndex: Int? = nil,
                            pointer: CGPoint? = nil,
                            using capturer: ScreenCapturing,
                            options: CaptureOptions) async throws -> Result? {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        let ordered = orderedForScripting(frames)
        let frame: DisplayFrame?
        if let displayIndex {
            // Out of range is nil rather than the nearest display: a script asking for monitor 3
            // on a two-monitor Mac has a bug, and quietly answering with monitor 2 hides it.
            frame = ordered.indices.contains(displayIndex - 1) ? ordered[displayIndex - 1] : nil
        } else if let pointer {
            frame = ordered.first { $0.geometry.frame.contains(pointer) } ?? ordered.first
        } else {
            frame = ordered.first
        }
        guard let frame else { throw CaptureError.noDisplays }

        // The rect arrives relative to that screen's lower-left corner; everything downstream
        // works in global points.
        let global = rect.offsetBy(dx: frame.geometry.frame.minX, dy: frame.geometry.frame.minY)
        let clamped = CaptureGeometry.clamp(global, to: frame.geometry)
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: clamped, in: frame.geometry)
        guard let cropped = frame.image.cropping(to: pixels.integral) else { return nil }
        return Result(image: cropped, sourceRect: clamped, display: frame.geometry)
    }

    /// Displays in the order a script counts them: the main one is 1, the rest left to right.
    ///
    /// `snapshotAllDisplays` returns whatever ScreenCaptureKit enumerated, and that order is not
    /// promised to be stable across launches — which would make `display=2` mean a different
    /// monitor on different days.
    static func orderedForScripting(_ frames: [DisplayFrame]) -> [DisplayFrame] {
        let main = CGMainDisplayID()
        return frames.sorted { lhs, rhs in
            if (lhs.geometry.displayID == main) != (rhs.geometry.displayID == main) {
                return lhs.geometry.displayID == main
            }
            if lhs.geometry.frame.minX != rhs.geometry.frame.minX {
                return lhs.geometry.frame.minX < rhs.geometry.frame.minX
            }
            return lhs.geometry.displayID < rhs.geometry.displayID
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
            guard let picked = try await captureArea(
                using: capturer, options: options,
                chrome: chrome.saying("Self-Timer — draw the area, then \(seconds)s to arrange"))
            else { return nil }
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

    /// One shortcut, every mode: freeze once, then choose on top of the frozen screen.
    ///
    /// **The point is that the screen is already frozen and already ready to drag.** The bar used
    /// to float over the live desktop, and choosing a mode dismissed it and started the capture
    /// from scratch — two freezes, and a menu you were trying to photograph got a whole round
    /// trip in which to close itself. Here the overlay goes up first with Area live, so the common
    /// case is press the shortcut and drag; the bar is for when you want one of the others.
    ///
    /// **The picker never resolves the capture for the area-shaped modes.** Scrolling, text and
    /// the self-timer all aim with the selection that is already on screen, so choosing one only
    /// changes the label and what happens to the rect afterwards. Resolving early there would
    /// abandon the drag the user was in the middle of.
    ///
    /// Window capture is the one mode that starts again, and has to: a window's shadow and its
    /// transparent background do not exist in a frozen picture of the desktop. See `captureWindow`.
    static func captureAllInOne(memory: CaptureModeMemory,
                                timerSeconds: Int,
                                using capturer: ScreenCapturing,
                                options: CaptureOptions,
                                chrome: CaptureOverlayController.Chrome,
                                onChoice: @escaping (CaptureModeMemory, Int) -> Void)
        async throws -> (result: Result?, mode: CaptureMode) {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        // What the bar settled on. Starts at what it opens on, so a straight drag with no visit
        // to the bar is an ordinary area capture.
        var mode = memory.mode
        var seconds = timerSeconds

        let choice: Choice = await withCheckedContinuation { continuation in
            var resumed = false
            @MainActor func finish(_ choice: Choice) {
                guard !resumed else { return }
                resumed = true
                AllInOneController.shared.dismiss()
                continuation.resume(returning: choice)
            }

            CaptureOverlayController.shared.present(
                frames: frames, chrome: chrome.saying(Self.hint(for: mode, seconds))
            ) { image, display, rect in
                guard let image, let rect, let display else { finish(.cancelled); return }
                finish(.region(image: image, rect: rect, display: display))
            }

            AllInOneController.shared.present(memory: memory, timerSeconds: timerSeconds,
                                              overFrozenScreen: true) { picked in
                // Escape belongs to the overlay underneath, which cancels the whole capture.
                guard let (picked, pickedSeconds) = picked else { return }
                onChoice(picked, pickedSeconds)
                mode = picked.mode
                seconds = pickedSeconds
                switch picked.mode {
                case .fullscreen:
                    guard let frame = CaptureOverlayController.shared.frameUnderPointer() else {
                        finish(.cancelled); return
                    }
                    CaptureOverlayController.shared.dismiss()
                    finish(.whole(frame))
                case .window:
                    CaptureOverlayController.shared.dismiss()
                    finish(.needsWindowPicker)
                default:
                    // Keep the drag that is already available: only the label changes here.
                    AllInOneController.shared.dismiss()
                    CaptureOverlayController.shared.setHint(Self.hint(for: picked.mode,
                                                                      pickedSeconds))
                }
            }
        }

        switch choice {
        case .cancelled:
            return (nil, mode)
        case .whole(let frame):
            return (Result(image: frame.image, sourceRect: frame.geometry.frame,
                           display: frame.geometry), .fullscreen)
        case .needsWindowPicker:
            return (try await captureWindow(using: capturer, options: options), .window)
        case .region(let image, let rect, let display):
            let result = try await resolve(mode: mode, seconds: seconds,
                                           image: image, rect: rect, display: display,
                                           using: capturer, options: options)
            return (result, mode)
        }
    }

    /// Turns the rect the user drew into whatever the chosen mode actually produces.
    private static func resolve(mode: CaptureMode, seconds: Int,
                                image: CGImage, rect: CGRect,
                                display: DisplaySnapshotGeometry,
                                using capturer: ScreenCapturing,
                                options: CaptureOptions) async throws -> Result? {
        if seconds > 0 {
            // Aimed on the frozen frame, captured live — a countdown over a picture taken before
            // the countdown defeats the whole point of having one.
            await withCheckedContinuation { continuation in
                CountdownPresenter.shared.run(seconds: seconds) { _ in continuation.resume() }
            }
            return try await captureRectLive(rect, on: display, using: capturer, options: options)
        }

        switch mode {
        case .scrolling:
            let stitched: CGImage? = await withCheckedContinuation { continuation in
                ScrollCaptureSession.shared.start(region: rect, display: display,
                                                  capturer: capturer, options: options) {
                    continuation.resume(returning: $0)
                }
            }
            guard let stitched else { return nil }
            return Result(image: stitched, sourceRect: rect, display: display)
        default:
            // Area and text recognition both want exactly the pixels that were drawn over.
            return Result(image: image, sourceRect: rect, display: display)
        }
    }

    /// Re-captures a rect from a fresh snapshot, for the modes that must not use frozen pixels.
    private static func captureRectLive(_ rect: CGRect, on display: DisplaySnapshotGeometry,
                                        using capturer: ScreenCapturing,
                                        options: CaptureOptions) async throws -> Result? {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard let frame = frames.first(where: { $0.geometry.displayID == display.displayID })
        else { throw CaptureError.noDisplays }
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: rect, in: frame.geometry)
        guard let cropped = frame.image.cropping(to: pixels.integral) else { return nil }
        return Result(image: cropped, sourceRect: rect, display: frame.geometry)
    }

    private enum Choice {
        case cancelled
        case whole(DisplayFrame)
        case needsWindowPicker
        case region(image: CGImage, rect: CGRect, display: DisplaySnapshotGeometry)
    }

    /// What the overlay says it is for, when that is not obvious from the overlay itself.
    static func hint(for mode: CaptureMode, _ seconds: Int) -> String? {
        if seconds > 0 { return "Self-Timer — draw the area, then \(seconds)s to arrange" }
        switch mode {
        case .scrolling: return "Scrolling Capture — draw the area, then scroll it"
        case .textRecognition: return "Copy Text — draw the area to read"
        default: return nil
        }
    }

    /// Pick a region, then capture it repeatedly while the user scrolls, and stitch.
    static func captureScrolling(using capturer: ScreenCapturing,
                                 options: CaptureOptions,
                                 chrome: CaptureOverlayController.Chrome) async throws -> Result? {
        guard let picked = try await captureArea(using: capturer, options: options,
                                                 chrome: chrome.saying(
                                                     "Scrolling Capture — draw the area, then scroll it")),
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
        try await captureArea(using: capturer, options: options,
                              chrome: chrome.saying("Copy Text — draw the area to read"))
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
