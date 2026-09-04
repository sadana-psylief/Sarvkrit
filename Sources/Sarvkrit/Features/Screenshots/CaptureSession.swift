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
                              options: CaptureOptions,
                              fromList: Bool = false) async throws -> Result? {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let windows = WindowPicker.capturable(
            from: try await capturer.shareableWindows(),
            excludingBundleIDs: options.excludedBundleIDs,
            desktopIconLayer: iconLayer)

        // Falls back to pointing when there is nothing to list — an empty picker is a dead end,
        // where the frozen screen at least shows what is there.
        let picked: CapturableWindow?
        let listed = WindowListFilter.presentable(windows)
        if fromList, !listed.isEmpty {
            // **Each window captured on its own, not cut out of the frozen desktop.** A crop shows
            // whatever is in *front* of the window, so two overlapping windows produced two
            // identical thumbnails — a picker that cannot tell its rows apart. A
            // desktop-independent capture is the window's own content whether or not anything
            // covers it, which is the whole reason `captureWindow` exists.
            let previews = await windowPreviews(for: listed, using: capturer, options: options)
            picked = await withCheckedContinuation { continuation in
                WindowPickerListController.shared.present(
                    windows: listed,
                    thumbnail: { previews[$0.id] },
                    completion: { continuation.resume(returning: $0) })
            }
        } else {
            picked = await withCheckedContinuation { continuation in
                CaptureOverlayController.shared.presentWindowPicker(
                    frames: frames, windows: windows) { continuation.resume(returning: $0) }
            }
        }
        guard let picked else { return nil }

        let capture = try await capturer.captureWindow(picked, options: options)
        return Result(image: capture.image,
                      sourceRect: picked.frame,
                      display: frames.first { $0.geometry.frame.intersects(picked.frame) }?.geometry)
    }

    /// A thumbnail per window, captured concurrently.
    ///
    /// Bounded by the list filter, which leaves a handful of real windows rather than the dozens
    /// of system panels the raw enumeration reports — so this is a few captures, not a few dozen.
    /// A window that will not render comes back missing and the row shows a placeholder; it is
    /// still capturable, so hiding it would be worse than showing it plain.
    private static func windowPreviews(for windows: [CapturableWindow],
                                       using capturer: ScreenCapturing,
                                       options: CaptureOptions) async -> [CGWindowID: NSImage] {
        var previews: [CGWindowID: NSImage] = [:]
        for window in windows {
            guard let capture = try? await capturer.captureWindow(window, options: options) else {
                continue
            }
            previews[window.id] = NSImage(cgImage: capture.image,
                                          size: NSSize(width: capture.image.width / 2,
                                                       height: capture.image.height / 2))
        }
        return previews
    }

    /// The one interactive capture: freeze, aim, confirm.
    ///
    /// **Every drag-aimed mode comes through here**, which is the point. Area, scrolling, text
    /// recognition, the self-timer and All-In-One were five paths that each froze the screen,
    /// each presented the overlay, and each did something different afterwards — so the step that
    /// actually takes the shot was implemented five times and explained none. One path means one
    /// place decides what the confirm button says and one place resolves the rect.
    ///
    /// `showsBarImmediately` is the only difference All-In-One now has: its bar is up before
    /// anything is drawn, because choosing the mode *is* the point of that shortcut. Every other
    /// mode shows the same bar the moment a rect settles.
    ///
    /// Window capture is the one mode that starts again rather than using the frozen pixels: a
    /// window's shadow and its transparent background do not exist in a photograph of the desktop.
    static func captureInteractive(startingMode: CaptureMode,
                                   memory: CaptureModeMemory,
                                   timerSeconds: Int,
                                   showsBarImmediately: Bool,
                                   initialSelection: CGRect? = nil,
                                   choosesWindowFromList: Bool = false,
                                   using capturer: ScreenCapturing,
                                   options: CaptureOptions,
                                   chrome: CaptureOverlayController.Chrome,
                                   onChoice: @escaping (CaptureModeMemory, Int) -> Void)
        async throws -> (result: Result?, mode: CaptureMode) {
        let frames = try await capturer.snapshotAllDisplays(options: options)
        guard !frames.isEmpty else { throw CaptureError.noDisplays }

        // Starts at what the shortcut asked for, so confirming without touching the bar does
        // exactly what the shortcut said it would.
        var mode = startingMode
        var seconds = timerSeconds
        var memory = memory

        let choice: Choice = await withCheckedContinuation { continuation in
            var resumed = false
            @MainActor func finish(_ choice: Choice) {
                guard !resumed else { return }
                resumed = true
                AllInOneController.shared.dismiss()
                continuation.resume(returning: choice)
            }

            var overlayChrome = chrome.saying(Self.hint(for: mode, seconds))
            overlayChrome.initialSelection = initialSelection
            overlayChrome.actionBar = .init(
                mode: mode,
                memory: memory,
                timerSeconds: seconds,
                onModeChanged: { picked, pickedSeconds in
                    mode = picked
                    seconds = pickedSeconds
                    memory.mode = picked
                    onChoice(memory, pickedSeconds)
                },
                onLeaveForMode: { picked in
                    mode = picked
                    memory.mode = picked
                    onChoice(memory, seconds)
                    switch picked {
                    case .window:
                        CaptureOverlayController.shared.dismiss()
                        finish(.needsWindowPicker)
                    default:
                        guard let frame = CaptureOverlayController.shared.frameUnderPointer() else {
                            finish(.cancelled); return
                        }
                        CaptureOverlayController.shared.dismiss()
                        finish(.whole(frame))
                    }
                })

            CaptureOverlayController.shared.present(frames: frames, chrome: overlayChrome) {
                image, display, rect in
                guard let image, let rect, let display else { finish(.cancelled); return }
                finish(.region(image: image, rect: rect, display: display))
            }

            guard showsBarImmediately else { return }
            AllInOneController.shared.present(memory: memory, timerSeconds: seconds,
                                              overFrozenScreen: true) { picked in
                // Escape belongs to the overlay underneath, which cancels the whole capture.
                guard let (picked, pickedSeconds) = picked else { return }
                onChoice(picked, pickedSeconds)
                mode = picked.mode
                seconds = pickedSeconds
                memory = picked
                switch picked.mode {
                case .fullscreen, .allDisplays:
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
                           display: frame.geometry), mode)
        case .needsWindowPicker:
            return (try await captureWindow(using: capturer, options: options,
                                            fromList: choosesWindowFromList), .window)
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
            let outcome: ScrollCaptureSession.Outcome = await withCheckedContinuation {
                continuation in
                ScrollCaptureSession.shared.start(region: rect, display: display,
                                                  capturer: capturer, options: options) {
                    continuation.resume(returning: $0)
                }
            }
            switch outcome {
            case .stitched(let image):
                return Result(image: image, sourceRect: rect, display: display)
            case .cancelled:
                return nil
            case .failed(let reason):
                // Said out loud. A failed stitch used to return the same nothing a cancel does,
                // so a long scroll that did not join up looked exactly like pressing Escape.
                ToastPresenter.shared.show(reason, symbolName: "arrow.down.doc")
                return nil
            }
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
