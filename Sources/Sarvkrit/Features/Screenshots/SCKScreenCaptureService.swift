import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// The only file in the app that imports ScreenCaptureKit.
///
/// Everything else works against `ScreenCapturing`, so the untestable surface is this file and
/// nothing else — and the app-hosted test bundle never touches TCC.
///
/// **Denial has no error to catch.** A missing Screen Recording grant doesn't throw; SCK simply
/// reports no displays, or hands back black images. `shareableDisplays()` returning empty is
/// therefore load-bearing: it is what `ScreenRecordingRelaunch.looksLikeStaleGrant` reads.
final class SCKScreenCaptureService: ScreenCapturing {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    // MARK: - Enumeration

    private func content(excludingDesktopWindows: Bool = false) async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            excludingDesktopWindows, onScreenWindowsOnly: true)
    }

    func shareableDisplays() async throws -> [DisplaySnapshotGeometry] {
        let content = try await content()
        return content.displays.map { Self.geometry(for: $0) }
    }

    func shareableWindows() async throws -> [CapturableWindow] {
        let content = try await content()
        return content.windows.compactMap { window in
            // Zero-size windows are real and numerous — offscreen helpers, status items with no
            // content — and none of them are things a person means to screenshot.
            guard window.frame.width > 1, window.frame.height > 1 else { return nil }
            return CapturableWindow(
                id: window.windowID,
                frame: Self.cocoaFrame(fromCGFrame: window.frame),
                title: window.title,
                owningBundleID: window.owningApplication?.bundleIdentifier,
                owningAppName: window.owningApplication?.applicationName,
                layer: window.windowLayer,
                isOnScreen: window.isOnScreen
            )
        }
    }

    // MARK: - Capture

    func snapshotAllDisplays(options: CaptureOptions) async throws -> [DisplayFrame] {
        let content = try await content()
        guard !content.displays.isEmpty else { throw CaptureError.noDisplays }

        // Sequential rather than concurrent, deliberately: SCK serialises these internally anyway,
        // and issuing them in parallel made no measurable difference while making the ordering of
        // the returned frames nondeterministic.
        var frames: [DisplayFrame] = []
        for display in content.displays {
            let filter = Self.filter(for: display, content: content, options: options)
            let image = try await Self.capture(filter: filter, options: options, isWindow: false)
            frames.append(DisplayFrame(geometry: Self.geometry(for: display, filter: filter),
                                       image: image))
        }
        return frames
    }

    func captureDisplay(_ display: DisplaySnapshotGeometry,
                        options: CaptureOptions) async throws -> CGImage {
        let content = try await content()
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID })
        else { throw CaptureError.displayGone }
        let filter = Self.filter(for: scDisplay, content: content, options: options)
        return try await Self.capture(filter: filter, options: options, isWindow: false)
    }

    func captureWindow(_ window: CapturableWindow,
                       options: CaptureOptions) async throws -> WindowCapture {
        let content = try await content()
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id })
        else { throw CaptureError.windowGone }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let image = try await Self.capture(filter: filter, options: options, isWindow: true)
        return WindowCapture(image: image,
                             contentRect: filter.contentRect,
                             scale: CGFloat(filter.pointPixelScale))
    }

    // MARK: - Filters

    /// A display filter that leaves Sarvkrit out of the shot.
    ///
    /// **This is how the overlay, the Quick Access panels and pinned windows stay out of every
    /// capture** — including the freeze-off path, where the overlay is genuinely on screen at the
    /// moment of capture. The alternative, hiding our own windows around each capture, flickers
    /// and races with the compositor.
    private static func filter(for display: SCDisplay,
                               content: SCShareableContent,
                               options: CaptureOptions) -> SCContentFilter {
        let excludedApps = content.applications.filter {
            options.excludedBundleIDs.contains($0.bundleIdentifier)
        }

        // Desktop icons live in Finder windows at a known layer. Excluding them beats
        // `defaults write com.apple.finder CreateDesktop false; killall Finder`, which is
        // destructive, visible, slow, and leaves the user's Finder restarted if we crash midway.
        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let excludedWindows = options.hidesDesktopIcons
            ? content.windows.filter { $0.windowLayer == iconLayer }
            : []

        return SCContentFilter(display: display,
                               excludingApplications: excludedApps,
                               exceptingWindows: excludedWindows)
    }

    private static func capture(filter: SCContentFilter,
                                options: CaptureOptions,
                                isWindow: Bool) async throws -> CGImage {
        let config = configuration(for: filter, options: options, isWindow: isWindow)
        return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                          configuration: config)
    }

    /// - Note: sized from `filter.contentRect`, never from a window's frame. See
    ///   `CaptureConfigurationMath` for why that distinction is load-bearing.
    static func configuration(for filter: SCContentFilter,
                              options: CaptureOptions,
                              isWindow: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = CaptureConfigurationMath.pixelSize(contentRect: filter.contentRect,
                                                      pointPixelScale: scale)
        config.width = size.width
        config.height = size.height
        config.showsCursor = options.showsCursor
        config.captureResolution = .best

        // Forced sRGB. An HDR or P3 display hands back an extended-range buffer, and a PNG written
        // from one without conversion comes out visibly washed out — which reads as a broken
        // screenshot tool rather than a colour-space mismatch.
        config.colorSpaceName = CGColorSpace.sRGB

        if isWindow {
            config.ignoreShadowsSingleWindow = !options.includesShadow
            config.ignoreGlobalClipSingleWindow = true
            if options.transparentBackground {
                // The alpha is only meaningful with a desktop-independent filter; with a display
                // filter the desktop is genuinely behind the window and there is nothing to see through.
                config.backgroundColor = .clear
                config.pixelFormat = kCVPixelFormatType_32BGRA
            }
        }
        return config
    }

    // MARK: - Geometry

    private static func geometry(for display: SCDisplay,
                                 filter: SCContentFilter? = nil) -> DisplaySnapshotGeometry {
        let frame = cocoaFrame(fromCGFrame: display.frame)
        // pointPixelScale when we have a filter, because that is what sized the buffer. Falling
        // back to the NSScreen match is only for enumeration, where no capture has happened yet.
        let scale = filter.map { CGFloat($0.pointPixelScale) }
            ?? NSScreen.screens.first {
                ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
                    == display.displayID
            }?.backingScaleFactor
            ?? 1
        return DisplaySnapshotGeometry(
            displayID: display.displayID,
            frame: frame,
            scale: scale,
            pixelSize: CGSize(width: frame.width * scale, height: frame.height * scale))
    }

    /// SCK reports frames in CoreGraphics' global space (top-left origin, y down); the rest of the
    /// app works in AppKit's (bottom-left, y up). Flipped against the **primary** display's height,
    /// which is the same global flip `ScreenCoordinates` performs — not the per-display flip in
    /// `CaptureGeometry`. The two are easy to mix up; see that file's comment.
    private static func cocoaFrame(fromCGFrame frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX,
                      y: primaryHeight - frame.maxY,
                      width: frame.width,
                      height: frame.height)
    }
}
