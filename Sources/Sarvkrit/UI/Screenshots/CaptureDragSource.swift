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

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.url = url
        view.preview = preview
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.url = url
        view.preview = preview
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var url: URL?
        var preview: NSImage?

        /// Swallowed so `mouseDragged` arrives. Handing it on would let the panel's own drag
        /// handle claim the gesture and move the window instead — the same split
        /// `WindowDragHandle` documents from the other side.
        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            guard let url else { return }
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
