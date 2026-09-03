import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import os

/// Turning a `CGImage` into bytes, a file, and a pasteboard entry.
///
/// Kept apart from the capture itself so the "what happens next" half has no ScreenCaptureKit in
/// it, and so `AppIdentity.isRunningTests` has one place to guard rather than several.
enum CaptureWriter {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        // Explicit size in points, or the rep reports the pixel count as points and a 2x capture
        // opens at twice its intended size in Preview.
        rep.size = NSSize(width: image.width, height: image.height)
        return rep.representation(using: .png, properties: [:])
    }

    /// Puts a capture on the general pasteboard as PNG.
    ///
    /// **No-op under tests.** `AppIdentity.isRunningTests` guards it for the reason that flag
    /// exists: the test bundle runs inside the real app on the developer's own Mac, and a test
    /// that clobbers the pasteboard destroys whatever the person was in the middle of copying.
    @discardableResult
    static func copyToPasteboard(_ image: CGImage) -> Bool {
        guard !AppIdentity.isRunningTests else { return false }
        guard let data = pngData(from: image) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .png)
    }

    /// Writes a PNG, creating the directory if needed.
    @discardableResult
    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let data = pngData(from: image) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("couldn't write capture: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
