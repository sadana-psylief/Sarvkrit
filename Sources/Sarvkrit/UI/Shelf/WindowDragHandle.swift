import AppKit
import SwiftUI

/// Makes the region it backs drag the whole window, the way a title bar does.
///
/// The shelf panel is `.borderless`, so it has no title bar — and a title bar is the only surface
/// AppKit moves a window by on its own. Without this the panel cannot be moved at all: it lands
/// wherever the pointer was when a drag opened it, and if that covers the folder you were aiming
/// for, there is nothing you can do about it.
///
/// **Why not `isMovableByWindowBackground`, which is one line?** Two reasons, both specific to this
/// panel rather than general caution:
///
/// 1. **It would steal drags from the tiles.** `ShelfDragSource` covers only each tile's preview
///    image, so filenames, subtitles and the padding between tiles are *not* drag sources. Making
///    the whole background movable means grabbing a filename moves the window instead of dragging
///    the file out — trading this bug for a worse one.
/// 2. **It is unpredictable here.** That flag defers to the hit-tested view's
///    `mouseDownCanMoveWindow`, whose default varies with view opacity, and the shelf's content is
///    an `NSHostingView` over `.regularMaterial`. Whether any given point moved the window would be
///    a property of SwiftUI's internal view tree.
///
/// `performDrag(with:)` is the AppKit primitive built for exactly this — borderless windows that
/// need a custom grab region — and it makes the draggable area something we state rather than
/// something we hope for. That matters in this file's neighbourhood: an `ignoresMouseEvents = true`
/// once silently killed the shelf's drop callbacks, and a `DisclosureGroup` once rendered a toggle
/// that could not be clicked. Both looked correct.
///
/// Put it *behind* the content it should drag — `.background(WindowDragHandle())`. SwiftUI's own
/// controls then sit above it and take their own clicks, while the gaps between them fall through
/// to here. That is precisely how a real title bar behaves, and it needs no hit-testing arithmetic.
struct WindowDragHandle: NSViewRepresentable {

    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ view: DragHandleView, context: Context) {}

    /// Transparent, and does nothing but hand the mouse-down to the window.
    final class DragHandleView: NSView {

        /// Unlike `ShelfDragSource.DragSourceView`, which swallows `mouseDown` so that
        /// `mouseDragged` will arrive, this hands the event straight over. `performDrag` runs its
        /// own event-tracking loop until the mouse comes up, so there is no drag threshold to
        /// implement and no second event to wait for.
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        /// Keeps `mouseDown` above as the *only* way this view moves the window.
        ///
        /// The inherited value is true for a non-opaque view, which would let AppKit's own
        /// background-drag machinery claim the event and never call `mouseDown` — so if anyone
        /// later switches `isMovableByWindowBackground` on, the behaviour here would silently
        /// change hands. Pinning it to false means one code path, always.
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
