import Foundation

/// When to take the next frame of a scrolling capture.
///
/// Pure, so momentum, a pause mid-scroll, and a scroll that never stops are tests rather than
/// things you reproduce by flicking a trackpad and watching.
///
/// **Capturing on quiescence rather than on every event is what handles momentum for free.**
/// Inertial scrolling keeps delivering events as it decelerates; waiting for a gap means the frame
/// is taken once the page has settled, so it is sharp and its overlap with the previous frame is
/// meaningful.
enum ScrollQuiescence {

    /// How long the scroll must be still before a frame is worth taking.
    static let defaultThreshold: TimeInterval = 0.15

    static func shouldCapture(lastEventAt: Date?,
                              lastCaptureAt: Date?,
                              now: Date,
                              threshold: TimeInterval = defaultThreshold) -> Bool {
        // Nothing has moved yet: the first frame is taken when the session starts, not here.
        guard let lastEventAt else { return false }
        guard now.timeIntervalSince(lastEventAt) >= threshold else { return false }
        // Don't take the same still frame repeatedly while the user reads the page.
        if let lastCaptureAt, lastCaptureAt >= lastEventAt { return false }
        return true
    }
}
