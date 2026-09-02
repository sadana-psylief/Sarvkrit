import Foundation

/// Remembers which keyDowns were rewritten, so their keyUps can be rewritten to match.
///
/// A rewritten ⌘X keyDown reaches Finder as ⌘C. Its keyUp must be rewritten identically or the
/// receiving app sees a C go down and an X come up, and its idea of what is held stops matching
/// reality.
///
/// **Exists as its own type because the obvious `Set<Int64>` is a bug.** A keyDown can be rewritten
/// and its keyUp then never arrive: the user switches apps mid-chord, a password field takes focus
/// and we stand down, or a resync rebuilds the tap between the two. Membership alone can't tell a
/// keycode that is genuinely mid-press from one stranded minutes ago, so the stale entry silently
/// rewrites the *next* press of that key — an X keyUp becoming a C keyUp in some unrelated app.
///
/// Pairing each keycode with when it was recorded makes the state self-correcting: entries older
/// than a plausible keypress are simply not honoured. Callers may still clear eagerly when they
/// know a down and its up have been separated; this is the backstop for the cases they can't see.
struct PendingRewrites {

    /// How long a rewritten keyDown may wait for its keyUp.
    ///
    /// Generous on purpose. A key is realistically held for well under a second, and the cost of
    /// being too generous is only that a genuinely stranded keycode lingers a little longer, while
    /// the cost of being too mean is a mismatched down/up pair on a key someone is holding down.
    static let window: TimeInterval = 5

    private var recorded: [Int64: TimeInterval] = [:]

    /// - Parameter now: injected so the expiry is testable without sleeping.
    mutating func record(_ keyCode: Int64, now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        recorded[keyCode] = now
        // Opportunistic sweep. Without it a long session accumulates one entry per key ever
        // stranded, which is small but unbounded.
        recorded = recorded.filter { now - $0.value <= Self.window }
    }

    /// Consumes the record for `keyCode` and says whether its keyUp should be rewritten.
    ///
    /// Consuming either way matters: a keycode that has expired is removed rather than left to be
    /// reconsidered on the following keyUp.
    mutating func consume(
        _ keyCode: Int64, now: TimeInterval = Date.timeIntervalSinceReferenceDate
    ) -> Bool {
        guard let recordedAt = recorded.removeValue(forKey: keyCode) else { return false }
        return now - recordedAt <= Self.window
    }

    mutating func removeAll() {
        recorded.removeAll()
    }

    var isEmpty: Bool { recorded.isEmpty }
}
