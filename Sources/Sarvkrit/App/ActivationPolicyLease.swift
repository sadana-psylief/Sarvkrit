import AppKit

/// Refcounts "some window needs this to be a regular app".
///
/// **This exists because the unconditional version is a latent bug the moment there is a second
/// window.** `MainWindowController` flips to `.regular` on show and back to `.accessory` on close,
/// and its own comment explains why the flip is needed at all: an `.accessory` app cannot fully
/// activate, so its windows "appear, then ignore clicks and typing". With an editor open too,
/// closing the settings window would drop the whole app back to `.accessory` and the editor would
/// stay on screen while quietly refusing input — which looks like a hang, not a policy change.
///
/// Counting is the fix: the policy goes up on the first window that needs it and comes down only
/// when the last one goes.
@MainActor
final class ActivationPolicyLease {
    static let shared = ActivationPolicyLease()

    private(set) var count = 0

    /// - Returns: true if this call is the one that changed the policy, so the caller knows
    ///   whether it still needs to activate.
    @discardableResult
    func acquire() -> Bool {
        count += 1
        guard count == 1 else { return false }
        NSApp.setActivationPolicy(.regular)
        return true
    }

    func release() {
        // Guarded rather than allowed to go negative: an over-release from a window controller
        // that closes twice would otherwise let the *next* acquire fail to raise the policy.
        guard count > 0 else { return }
        count -= 1
        guard count == 0 else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
