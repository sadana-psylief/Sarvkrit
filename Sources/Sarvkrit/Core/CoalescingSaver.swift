import Foundation
import os

/// Writes the latest snapshot of something to disk, off the main thread, without queueing up
/// every intermediate state.
///
/// **Extracted because this is the third copy.** `ClipboardStore` wrote it, `ShelfStore` copied
/// it, and a capture history would have made three — which is the bar `ScreenPlacement` sets in
/// its own comment: "Two is a coincidence; three is a helper."
///
/// The behaviour that matters, and the reason it isn't just `DispatchQueue.async`:
///
/// - **Coalescing.** Ten changes in a row cause one write, of the tenth state. Persisting is
///   idempotent — only the newest snapshot means anything — so writing the nine older ones is
///   pure cost, paid on a queue that a burst can saturate.
/// - **Off the main thread.** The event tap's run loop lives there, and a synchronous write on
///   every change is felt as input latency system-wide.
/// - **`flush()` on quit.** The trade above is only safe if quitting waits for the last write.
///   Otherwise the most recent change — the one the user just made — is the one that gets lost.
///
/// The existing two stores are deliberately *not* retrofitted onto this. `ClipboardStore` carries
/// a hand-written decoder that `ClipboardMigrationTests` guards and `ShelfItem`'s comment calls
/// load-bearing for existing users' history; changing how they persist in the same breath as
/// adding a new feature is how migrations get broken.
final class CoalescingSaver<Snapshot> {
    private let write: (Snapshot) -> Void
    private let queue: DispatchQueue

    private var pending: Snapshot?
    private var isDraining = false
    private var lock = os_unfair_lock_s()

    init(label: String, qos: DispatchQoS = .utility, write: @escaping (Snapshot) -> Void) {
        self.write = write
        self.queue = DispatchQueue(label: label, qos: qos)
    }

    /// Records a snapshot to be written. Returns immediately.
    func schedule(_ snapshot: Snapshot) {
        os_unfair_lock_lock(&lock)
        pending = snapshot
        let alreadyRunning = isDraining
        if !alreadyRunning { isDraining = true }
        os_unfair_lock_unlock(&lock)

        guard !alreadyRunning else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            os_unfair_lock_lock(&lock)
            let snapshot = pending
            pending = nil
            if snapshot == nil { isDraining = false }
            os_unfair_lock_unlock(&lock)

            guard let snapshot else { return }
            write(snapshot)
        }
    }

    /// Writes anything outstanding and waits for it. Called on quit, where "in flight somewhere"
    /// isn't good enough.
    func flush() {
        queue.sync { }
        os_unfair_lock_lock(&lock)
        let snapshot = pending
        pending = nil
        isDraining = false
        os_unfair_lock_unlock(&lock)
        if let snapshot { write(snapshot) }
    }
}
