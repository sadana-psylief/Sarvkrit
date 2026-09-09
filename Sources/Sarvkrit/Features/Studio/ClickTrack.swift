import CoreGraphics
import Foundation

/// A click placed by hand, rather than one the recording caught.
///
/// Carries its own point because the natural place for it is wherever the pointer was at that
/// moment, and resolving that once — when it is placed — keeps this a plain value.
struct ManualClick: Codable, Equatable, Identifiable {
    var id = UUID()
    var t: TimeInterval
    /// Recording pixel space, the same as `ClickEvent.point`.
    var point: CGPoint
    var button: ClickEvent.Button = .left
}

/// What the user changed about the clicks, kept beside the recording rather than in it.
///
/// **The recording is never modified.** A suppressed click is remembered by its time, not deleted,
/// so undo brings it back and nothing about the original take is lost.
struct ClickEdits: Codable, Equatable {
    var added: [ManualClick] = []
    /// Times of recorded presses the user took out.
    var suppressed: [TimeInterval] = []
}

/// The clicks a finished frame should show.
///
/// **Before this there was no way to edit a click at all.** `StudioRenderer` read the recording's
/// `pressDowns` directly, `EventLog.clicks` is `private(set)`, and `ClickEffect` holds no per-click
/// state — so a stray click during a take was in the video permanently, and a point worth
/// emphasising that nobody happened to click on could not be marked.
///
/// A pure resolver, in the shape this codebase already uses for decision logic, so the renderer
/// stays unaware of where any given click came from.
enum ClickTrack {

    /// How close two times must be to count as the same click.
    ///
    /// Times are floats that have been through JSON, so an exact match would let a suppressed click
    /// reappear on reload. A frame at 120fps is 8ms, so this is comfortably inside "the same click"
    /// while staying well clear of the next one.
    static let sameClickTolerance: TimeInterval = 0.001

    static func effective(recorded: [ClickEvent], edits: ClickEdits) -> [ClickEvent] {
        // Releases are not click effects; the renderer only ever asks about presses.
        let kept = recorded.filter { event in
            guard event.isDown else { return false }
            return !edits.suppressed.contains { abs($0 - event.t) <= sameClickTolerance }
        }
        let placed = edits.added.map {
            ClickEvent(t: $0.t, point: $0.point, button: $0.button, isDown: true, isInside: true)
        }
        return (kept + placed).sorted { $0.t < $1.t }
    }
}
