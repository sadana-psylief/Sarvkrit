import CoreGraphics
import Foundation

/// Remembers where a window was before Sarvkrit first moved it, so `Restore` can put it back.
///
/// Generic over the key purely so it can be tested without live `AXUIElement`s — the manipulator
/// keys it on the element itself, there being no public window ID to use instead.
///
/// The whole subtlety is in `record`. Snapping a window twice must not make the second snap the
/// thing we restore to; the user means "back where I had it", not "back to the last half". So a
/// window found sitting where we last put it keeps its original restore frame, and only a window
/// the *user* has since moved starts a new one.
struct RestoreMemory<Key: Hashable> {
    private struct Entry {
        /// Where the window was before we first touched it.
        var restore: CGRect
        /// The frame we last applied, so a frame the user moved can be told from one we placed.
        var applied: CGRect
    }
    private var entries: [Key: Entry] = [:]

    /// - Parameters:
    ///   - current: where the window is now, before this move.
    ///   - target: where it is about to be put.
    mutating func record(_ key: Key, current: CGRect, target: CGRect) {
        if let existing = entries[key], WindowLayout.matches(current, existing.applied) {
            // Still where we put it — this is snap number two. Keep the original restore frame
            // and only update what we're about to apply.
            entries[key] = Entry(restore: existing.restore, applied: target)
            return
        }
        entries[key] = Entry(restore: current, applied: target)
    }

    /// Whether the window is still sitting where we last put it, rather than somewhere the user
    /// has since moved it.
    func isWhereWePutIt(_ key: Key, current: CGRect) -> Bool {
        guard let entry = entries[key] else { return false }
        return WindowLayout.matches(current, entry.applied)
    }

    /// Nil for a window we have no record of — `Restore` then does nothing rather than guessing.
    func restoreFrame(for key: Key) -> CGRect? { entries[key]?.restore }

    /// After restoring, the window is back at its original frame; that frame is now what we last
    /// applied, so a further restore is a no-op rather than a jump.
    mutating func markRestored(_ key: Key) {
        guard let existing = entries[key] else { return }
        entries[key] = Entry(restore: existing.restore, applied: existing.restore)
    }

    mutating func removeAll() { entries.removeAll() }

    var count: Int { entries.count }
}
