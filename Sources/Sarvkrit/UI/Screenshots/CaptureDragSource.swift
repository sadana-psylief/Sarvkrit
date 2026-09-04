import AppKit
import SwiftUI

/// Drags a capture out of the overlay and into another app as a file.
///
/// Modelled on `ShelfDragSource` and deliberately not sharing it — that one drags a set of items
/// out of a grid and can clear the shelf afterwards; this drags exactly one file and never mutates
/// anything.
///
/// **It vends `NSURL`, not `NSImage`.** `ShelfDragSource`'s comment records the bug: Finder wants
/// `public.file-url`, and a drop carrying an in-memory image "quietly did nothing". That is the
/// reason the PNG is written to the history directory *before* the overlay appears rather than
/// when Save is clicked — there has to be a real file behind the thumbnail from the start.
struct CaptureDragSource: NSViewRepresentable {
    let url: URL
    /// Drawn under the pointer while dragging. Without one, AppKit drags an empty rectangle.
    let preview: NSImage?
    /// Called when the thumbnail is flicked off the side of the screen. **Nil means the gesture
    /// does not exist here** — the editor's drag-out proxy uses this same view and must never
    /// vanish when someone drags leftwards.
    var onSwipeAway: (() -> Void)?

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.url = url
        view.preview = preview
        view.onSwipeAway = onSwipeAway
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.url = url
        view.preview = preview
        view.onSwipeAway = onSwipeAway
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var url: URL?
        var preview: NSImage?
        var onSwipeAway: (() -> Void)?
        /// Where the press started, in screen points. Nil between gestures.
        private var pressOrigin: CGPoint?

        /// Swallowed so `mouseDragged` arrives. Handing it on would let the panel's own drag
        /// handle claim the gesture and move the window instead — the same split
        /// `WindowDragHandle` documents from the other side.
        override func mouseDown(with event: NSEvent) {
            pressOrigin = NSEvent.mouseLocation
        }

        override func mouseUp(with event: NSEvent) {
            pressOrigin = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let url else { return }

            // Decide before starting the session: once AppKit owns the drag there is no way back,
            // so a swipe that is recognised late is a swipe that never happens.
            if let onSwipeAway, let pressOrigin, let window, let screen = window.screen {
                switch QuickAccessSwipe.decide(from: pressOrigin, to: NSEvent.mouseLocation,
                                               panel: window.frame, screen: screen.frame) {
                case .undecided:
                    return
                case .dismiss:
                    self.pressOrigin = nil
                    onSwipeAway()
                    return
                case .dragOut:
                    break
                }
            }

            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let size = NSSize(width: 96, height: 96)
            item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil),
                                         size: size),
                                  contents: preview)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext)
            -> NSDragOperation {
            // `.copy` in both contexts: dragging a capture out must never be a *move* that
            // removes it from the history the user is still looking at.
            .copy
        }
    }
}
