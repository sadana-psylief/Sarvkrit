import CoreGraphics
import Foundation

/// Which window the pointer is over.
///
/// Pure, over a list of `CapturableWindow`, so the ordering rules are a test table rather than
/// something you verify by hovering over overlapping windows and squinting.
///
/// **Not the Accessibility API.** `WindowManipulator` enumerates windows through AX because it
/// needs to *move* them; a capture needs the list ScreenCaptureKit will actually accept as a
/// filter, and the two do not agree — AX can't see another app's windows without a grant this
/// feature deliberately doesn't ask for.
enum WindowPicker {

    /// Windows that make sense to capture, in front-to-back order.
    ///
    /// `SCShareableContent.windows` is already front-to-back, so this filters without re-sorting —
    /// re-sorting by anything we can see here would *lose* that ordering, since z-order is not
    /// derivable from a frame.
    static func capturable(from windows: [CapturableWindow],
                           excludingBundleIDs excluded: Set<String>,
                           desktopIconLayer: Int) -> [CapturableWindow] {
        windows.filter { window in
            guard window.isOnScreen else { return false }
            // Zero and near-zero windows are real and numerous — offscreen helpers, status items
            // with no content — and none of them are things a person means to screenshot.
            guard window.frame.width > 1, window.frame.height > 1 else { return false }
            // Our own overlay is on screen at this exact moment, and it covers everything.
            if let bundleID = window.owningBundleID, excluded.contains(bundleID) { return false }
            // The desktop itself is not a window anyone means to pick, and it would swallow every
            // hover that missed a real window.
            if window.layer == desktopIconLayer { return false }
            return true
        }
    }

    /// The window under a point.
    ///
    /// Front-most wins, which is what the user sees. Where a small window sits inside a larger
    /// one *at the same depth* — a sheet over its parent, a palette over a document — the smaller
    /// is preferred, because a window entirely covering another is almost never the one being
    /// aimed at.
    static func window(at point: CGPoint,
                       in windows: [CapturableWindow]) -> CapturableWindow? {
        let hits = windows.filter { $0.frame.contains(point) }
        guard !hits.isEmpty else { return nil }

        // The list is front-to-back, so the first hit is frontmost. Only prefer a smaller window
        // over it when that smaller one is fully contained within it — otherwise two side-by-side
        // windows would swap priority based on size, which is not what depth means.
        guard let front = hits.first else { return nil }
        let containedInFront = hits.dropFirst().filter { front.frame.contains($0.frame) }
        return containedInFront.min { $0.frame.area < $1.frame.area } ?? front
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
