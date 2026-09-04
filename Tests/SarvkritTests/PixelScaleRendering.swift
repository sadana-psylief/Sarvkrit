import AppKit
import XCTest

/// Rendering a view at a pixel scale the *test* chooses.
///
/// **`bitmapImageRepForCachingDisplay` follows the host's display.** On a Retina Mac it hands back
/// two device pixels per point; on CI's headless runner, one. Any test that counts pixels through
/// it is therefore measuring the machine as much as the code — five of them were tuned on a 2×
/// screen and failed on CI at exactly the quarter-count you would predict, which read as a bug in
/// the overlay and was not one.
///
/// This renders into a rep of an explicit size instead, so a count means the same thing everywhere
/// and both scales can be checked from one machine.
@MainActor
func renderPixels(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
    let rep = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(view.bounds.width) * scale,
        pixelsHigh: Int(view.bounds.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    // The rep is in device pixels; tell it how many points those are, or the view draws at 1:1
    // into the top-left corner of a 2× buffer.
    rep.size = view.bounds.size

    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    view.displayIgnoringOpacity(view.bounds, in: context)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Lets SwiftUI actually run an update.
///
/// `NSHostingView` re-runs `body` from a main-run-loop observer, not synchronously when a
/// `@Published` value changes — `layoutSubtreeIfNeeded()` alone does not flush it. Locally
/// something else pumped the loop and the update landed; on CI nothing did, so two renders came
/// back byte-identical and the tests read that as "the change never reached the screen".
@MainActor
func pumpRunLoop(_ interval: TimeInterval = 0.1) {
    RunLoop.main.run(until: Date().addingTimeInterval(interval))
}
