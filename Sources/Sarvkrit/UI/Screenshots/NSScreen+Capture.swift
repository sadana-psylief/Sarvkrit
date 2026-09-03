import AppKit
import CoreGraphics

/// The bridge between `NSScreen` and the capture layer's own geometry type.
///
/// Kept out of `CaptureGeometry` so that stays pure CoreGraphics and testable with synthetic
/// arrangements — the moment it imports AppKit, every test needs a real display.
extension NSScreen {

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Geometry for this screen, for use *before* a capture has happened.
    ///
    /// **`backingScaleFactor` is a placeholder here.** It is right for sizing an overlay window,
    /// which is all this is used for; every actual crop uses the scale that came back with the
    /// captured frame, which is `SCContentFilter.pointPixelScale`. The two disagree on a display
    /// running a scaled resolution.
    var captureGeometry: DisplaySnapshotGeometry {
        DisplaySnapshotGeometry(
            displayID: displayID ?? 0,
            frame: frame,
            scale: backingScaleFactor,
            pixelSize: CGSize(width: frame.width * backingScaleFactor,
                              height: frame.height * backingScaleFactor))
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}
