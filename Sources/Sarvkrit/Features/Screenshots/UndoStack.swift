import Foundation

/// Snapshot undo over a value type.
///
/// **Not `NSUndoManager`.** That groups by run-loop event, so a pencil stroke would land as dozens
/// of separate undo steps unless you call `beginUndoGrouping`/`endUndoGrouping` yourself — at
/// which point the coalescing logic is written anyway and the only thing gained is an untestable
/// Objective-C dependency. Snapshots also make "reopen a file and undo past where you saved" the
/// same operation as any other undo, rather than a special case.
///
/// The snapshots are vectors — a few hundred bytes of geometry — never the bitmap, so depth is
/// cheap.
struct UndoStack<Value: Equatable> {
    private(set) var current: Value
    private var past: [Value] = []
    private var future: [Value] = []
    private let depth: Int
    private var transactionDepth = 0
    /// The state as it was when the outermost transaction opened.
    private var transactionStart: Value?

    init(initial: Value, depth: Int = 200) {
        self.current = initial
        self.depth = max(1, depth)
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Records the current state and moves to `next`.
    ///
    /// A no-op commit is ignored, so a click that changes nothing doesn't cost an undo step the
    /// user then has to press twice to get past.
    mutating func commit(_ next: Value) {
        guard next != current else { return }
        if transactionDepth > 0 {
            // Inside a transaction the intermediate states are working state, not history.
            current = next
            return
        }
        past.append(current)
        if past.count > depth { past.removeFirst(past.count - depth) }
        future.removeAll()
        current = next
    }

    /// Everything between begin and end is one undo step. Nested begins are refcounted, so a
    /// gesture that internally calls another still collapses to a single entry.
    mutating func beginTransaction() {
        if transactionDepth == 0 { transactionStart = current }
        transactionDepth += 1
    }

    mutating func endTransaction(_ next: Value) {
        guard transactionDepth > 0 else { commit(next); return }
        transactionDepth -= 1
        guard transactionDepth == 0 else {
            current = next
            return
        }
        let start = transactionStart ?? current
        transactionStart = nil
        current = start
        commit(next)
    }

    @discardableResult
    mutating func undo() -> Value? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        current = previous
        return current
    }

    @discardableResult
    mutating func redo() -> Value? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        current = next
        return current
    }
}
