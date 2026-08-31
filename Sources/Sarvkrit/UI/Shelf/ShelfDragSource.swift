import AppKit
import SwiftUI

/// Makes a tile draggable, out to Finder and anywhere else.
///
/// **Replaces SwiftUI's `.onDrag`, which did not work for files.** The old code vended
/// `NSItemProvider(contentsOf: url)`, which offers the file's *contents*; Finder wants
/// `public.file-url` — a reference to the file, not its bytes — so a drop into a Finder window had
/// nothing it recognised and quietly did nothing.
///
/// `NSURL` conforms to `NSPasteboardWriting` and writes exactly that representation, which is why
/// this goes through AppKit. Two things fall out for free:
///
/// - **A session can carry several items.** `NSItemProvider` carries one, so the old path could only
///   ever drag the first file of a group — the grouping the store already models was unreachable.
/// - The drag image is ours to choose, so what moves under the pointer is the tile's own preview.
struct ShelfDragSource: NSViewRepresentable {
    let item: ShelfItem
    let store: ShelfStore
    /// Rendered under the pointer while dragging.
    let dragImage: NSImage?

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.configure(item: item, store: store, dragImage: dragImage)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.configure(item: item, store: store, dragImage: dragImage)
    }

    /// Transparent, sits over the tile, and starts the drag.
    final class DragSourceView: NSView, NSDraggingSource {
        private var item: ShelfItem?
        private var store: ShelfStore?
        private var dragImage: NSImage?

        func configure(item: ShelfItem, store: ShelfStore, dragImage: NSImage?) {
            self.item = item
            self.store = store
            self.dragImage = dragImage
        }

        override func mouseDown(with event: NSEvent) {
            // Swallowed rather than passed on: without handling mouseDown, `mouseDragged` never
            // arrives and the drag can't start.
        }

        override func mouseDragged(with event: NSEvent) {
            guard let items = draggingItems(), !items.isEmpty else { return }
            beginDraggingSession(with: items, event: event, source: self)
        }

        /// `.copy` everywhere: a shelf hands out references to what it holds, it doesn't give them
        /// away. Dragging a file out must never move the user's file.
        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            .copy
        }

        private func draggingItems() -> [NSDraggingItem]? {
            guard let item, let store else { return nil }

            switch item.kind {
            case .files(let references):
                // One dragging item per file, so a group of three arrives as three files.
                // An unresolvable reference vends nothing rather than a dead item.
                return references.compactMap { reference in
                    guard let url = store.resolve(reference) else { return nil }
                    return draggingItem(writer: url as NSURL)
                }

            case .text(let value):
                return [draggingItem(writer: value as NSString)]

            case .largeText(let fileName, let preview, _):
                guard let data = store.readPayload(fileName),
                      let value = String(data: data, encoding: .utf8)
                else { return [draggingItem(writer: preview as NSString)] }
                return [draggingItem(writer: value as NSString)]

            case .richText(_, let plain):
                // The plain twin, which is stored precisely so this path never depends on the rtf
                // file surviving.
                return [draggingItem(writer: plain as NSString)]

            case .image(let fileName, _, _, _):
                guard let data = store.readPayload(fileName), let image = NSImage(data: data) else {
                    return nil
                }
                return [draggingItem(writer: image)]
            }
        }

        private func draggingItem(writer: NSPasteboardWriting) -> NSDraggingItem {
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let image = dragImage ?? NSWorkspace.shared.icon(forFileType: "public.data")
            let size = image.size == .zero ? NSSize(width: 32, height: 32) : image.size
            draggingItem.setDraggingFrame(
                NSRect(origin: .zero, size: size),
                contents: image
            )
            return draggingItem
        }
    }
}
