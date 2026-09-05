import CoreGraphics
import Foundation

/// Which pointer was on screen. Raw values are persisted in the recording bundle.
///
/// **A kind, not a bitmap, wherever one can be recognised.** A 16×16 system cursor scaled to 3× is
/// the blurry mess this whole feature exists to avoid, so a recognised pointer is redrawn from
/// vector paths at whatever size the canvas wants. `.custom` is the honest admission that an app
/// shipped its own — Figma, Photoshop, a game — and there the captured bitmap is all there is.
enum CursorKind: String, Codable, CaseIterable, Equatable {
    case arrow
    case iBeam
    case pointingHand
    case openHand
    case closedHand
    case crosshair
    case resizeLeftRight
    case resizeUpDown
    case resizeDiagonal
    case notAllowed
    case contextualMenu
    /// An application's own pointer. `CursorSample.customCursorHash` names the stored bitmap.
    case custom
    /// Written by a newer build. Rendered as an arrow rather than as nothing.
    case unknown
}

/// Where the pointer was, sampled at the display's refresh rate.
///
/// Sampled rather than taken from move events, because move events stop arriving when the mouse
/// stops — and a path with no samples during a pause cannot be interpolated across it.
struct CursorSample: Codable, Equatable {
    /// Seconds from the first video frame. One clock for the whole bundle.
    var t: TimeInterval
    /// Recording space, top-left origin.
    var point: CGPoint
    var kind: CursorKind = .arrow
    /// Set only when `kind == .custom`. Names a file in the bundle's `cursors/`, deduplicated.
    var customCursorHash: String?
    /// Whether the pointer was within the recorded region. False happens constantly in area and
    /// window modes, and drawing a cursor pinned to the frame edge is worse than drawing none.
    var isInside: Bool = true
}

/// A press or a release. Both are kept: a drag is a down with a much later up, and the click
/// effect has to know which.
struct ClickEvent: Codable, Equatable {
    enum Button: String, Codable, Equatable { case left, right, other }

    var t: TimeInterval
    var point: CGPoint
    var button: Button
    var isDown: Bool
    var isInside: Bool = true
}

/// One keypress, as a *label* rather than a character.
///
/// "⌘C" is what a demo needs to show. The character someone typed into a password field is not
/// something this app should be holding at all, which is why the recorder drops those before they
/// reach here rather than filtering them later.
struct KeyEvent: Codable, Equatable {
    var t: TimeInterval
    /// Display-ready: "⌘C", "Space", "←".
    var label: String
    /// Whether this was a modifier combination rather than a bare character. The default keystroke
    /// setting shows only these.
    var isModifierCombination: Bool
}

/// Everything the recorder captured besides pixels.
///
/// **This is the difference between a screen recording and Screen Studio.** The cursor is not in
/// the video, so it is drawn from `cursor`; the zooms are invented from `clicks` and `keys`; the
/// keystroke overlay is drawn from `keys`. All of it stays editable afterwards because none of it
/// was ever baked in.
struct EventLog: Codable, Equatable {
    private(set) var cursor: [CursorSample]
    private(set) var clicks: [ClickEvent]
    private(set) var keys: [KeyEvent]
    /// Moments the user marked with ⌃⌥⌘F while recording.
    private(set) var flags: [TimeInterval]

    /// Sorted here rather than trusted from the file. The log is appended from a serial queue, but
    /// a recording recovered after a crash is truncated mid-write, and a reader that assumes order
    /// turns a partially-written tail into a cursor that jumps backwards.
    init(cursor: [CursorSample] = [], clicks: [ClickEvent] = [],
         keys: [KeyEvent] = [], flags: [TimeInterval] = []) {
        self.cursor = cursor.sorted { $0.t < $1.t }
        self.clicks = clicks.sorted { $0.t < $1.t }
        self.keys = keys.sorted { $0.t < $1.t }
        self.flags = flags.sorted()
    }

    var isEmpty: Bool { cursor.isEmpty && clicks.isEmpty && keys.isEmpty }

    // MARK: - Lookup

    /// The pointer's position at `t`, interpolated between the two samples either side.
    ///
    /// Held at the ends rather than extrapolated: past the last sample the recording is over and
    /// the pointer did not keep moving, so inventing a position would draw a cursor sliding off
    /// the frame during the final second.
    func cursorPoint(at t: TimeInterval) -> CGPoint? {
        guard let first = cursor.first, let last = cursor.last else { return nil }
        if t <= first.t { return first.point }
        if t >= last.t { return last.point }

        let index = indexOfSample(at: t)
        let before = cursor[index]
        guard index + 1 < cursor.count else { return before.point }
        let after = cursor[index + 1]

        let span = after.t - before.t
        guard span > 0 else { return before.point }
        let fraction = CGFloat((t - before.t) / span)
        return CGPoint(x: before.point.x + (after.point.x - before.point.x) * fraction,
                       y: before.point.y + (after.point.y - before.point.y) * fraction)
    }

    /// Whether the pointer was over the recorded region. A step, not a blend — it is a fact about
    /// one sample, and interpolating a boolean means inventing a half-visible cursor.
    func isCursorInside(at t: TimeInterval) -> Bool {
        guard !cursor.isEmpty else { return false }
        return cursor[indexOfSample(at: t)].isInside
    }

    /// The kind holds until the next sample changes it: it is a state, not an event.
    func cursorKind(at t: TimeInterval) -> CursorKind {
        guard !cursor.isEmpty else { return .arrow }
        return cursor[indexOfSample(at: t)].kind
    }

    func customCursorHash(at t: TimeInterval) -> String? {
        guard !cursor.isEmpty else { return nil }
        return cursor[indexOfSample(at: t)].customCursorHash
    }

    /// Presses only, which is what the zoom planner and the click effect both want.
    var pressDowns: [ClickEvent] { clicks.filter { $0.isDown } }

    /// The last sample at or before `t`, by binary search — a ten-minute recording at 120 Hz is
    /// seventy thousand samples and this is called for every layer of every frame.
    private func indexOfSample(at t: TimeInterval) -> Int {
        var low = 0, high = cursor.count - 1, best = 0
        while low <= high {
            let mid = (low + high) / 2
            if cursor[mid].t <= t {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    // MARK: - Recovery

    /// Cuts the log back to what the video actually contains.
    ///
    /// A recording recovered after a crash keeps whole fragments only, so the sidecars are longer
    /// than the picture. Without this the cursor carries on moving over a frozen final frame.
    func truncated(to t: TimeInterval) -> EventLog {
        EventLog(cursor: cursor.filter { $0.t <= t },
                 clicks: clicks.filter { $0.t <= t },
                 keys: keys.filter { $0.t <= t },
                 flags: flags.filter { $0 <= t })
    }
}
