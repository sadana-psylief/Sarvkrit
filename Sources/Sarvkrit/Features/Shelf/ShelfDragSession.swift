import Foundation

/// Decides when a system-wide drag has started and finished.
///
/// Pure, following `SnapDragSession`'s shape, because the AppKit half of this cannot be tested at
/// all — and the last thing shipped here was a confident claim about drag behaviour that turned out
/// to be false. Whatever can be checked, should be.
///
/// **Why two signals rather than one.** A dragged mouse is not a drag *session*: the pointer moving
/// with the button held is equally a text selection or a window move. What distinguishes a real
/// drag is that its source writes the drag pasteboard, bumping its change count.
///
/// And the count must be *compared*, never merely read — **the previous drag's contents sit on that
/// pasteboard indefinitely**, so finding something there proves nothing about now.
struct ShelfDragSession {

    enum Event: Equatable {
        /// The mouse moved with the left button down, and this is what the drag pasteboard's change
        /// count reads at that moment.
        case mouseDragged(changeCount: Int)
        case mouseUp
    }

    enum Effect: Equatable {
        case dragBegan
        case dragEnded
    }

    private var isDragging = false
    /// The change count belonging to the most recent session we recognised.
    private var lastSeenChangeCount: Int?

    /// Seeds the baseline so a drag that happened *before* the Shelf was switched on can't be
    /// mistaken for a new one the first time the mouse moves.
    mutating func begin(withChangeCount changeCount: Int) {
        lastSeenChangeCount = changeCount
        isDragging = false
    }

    mutating func handle(_ event: Event) -> Effect? {
        switch event {
        case .mouseDragged(let changeCount):
            guard !isDragging else { return nil }        // already in one; nothing new to report
            guard changeCount != lastSeenChangeCount else { return nil }   // stale pasteboard
            lastSeenChangeCount = changeCount
            isDragging = true
            return .dragBegan

        case .mouseUp:
            guard isDragging else { return nil }
            isDragging = false
            return .dragEnded
        }
    }

    /// Cleared when the feature is switched off, so a mouse-up arriving afterwards reports nothing.
    mutating func reset() {
        isDragging = false
        lastSeenChangeCount = nil
    }

    var isInProgress: Bool { isDragging }
}
