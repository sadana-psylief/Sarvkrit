import Foundation

/// Whether the microphone lock should put a mute back.
///
/// **The danger here is fighting itself.** The lock notices the mute changing and re-asserts it —
/// but our own re-assert is itself a change. Read naively, that is an infinite loop, and not a
/// harmless one: a microphone flapping between muted and live in the middle of a call is worse than
/// either state.
///
/// So a re-assert is expected, and an expected change is consumed rather than acted on. Pure,
/// because the loop is the kind of bug that is obvious in a table and invisible in a live system
/// until someone is mid-sentence.
struct PrivacyGuardState {

    enum Change: Equatable {
        /// The device reports it is now muted.
        case becameMuted
        /// The device reports it is now unmuted.
        case becameUnmuted
    }

    enum Action: Equatable {
        case doNothing
        /// Put the mute back.
        case reassertMute
    }

    /// Whether the lock is on. When off, nothing is ever re-asserted.
    var isLocked = false

    /// A mute we asked for and have not yet seen reflected.
    ///
    /// Without this the lock treats its own work as external interference.
    private var awaitingOwnMute = false

    /// Call immediately before asking the device to mute, so the resulting change is recognised as
    /// ours when it arrives.
    mutating func willAssertMute() {
        awaitingOwnMute = true
    }

    mutating func handle(_ change: Change) -> Action {
        switch change {
        case .becameMuted:
            // Ours or not, the device is now in the state we want. Either way there is nothing to
            // do, and the expectation is discharged.
            awaitingOwnMute = false
            return .doNothing

        case .becameUnmuted:
            guard isLocked else { return .doNothing }
            // An unmute is never something we asked for — the lock only ever mutes — so a pending
            // expectation is stale and must not suppress this.
            awaitingOwnMute = false
            return .reassertMute
        }
    }

    /// Whether a mute is currently expected to arrive. Exposed so a test can prove the expectation
    /// is actually cleared rather than accumulating.
    var isAwaitingOwnMute: Bool { awaitingOwnMute }

    /// What to do when the lock is switched on, or the app starts with it on.
    static func actionOnLockEngaged(currentlyMuted: Bool) -> Action {
        currentlyMuted ? .doNothing : .reassertMute
    }
}
