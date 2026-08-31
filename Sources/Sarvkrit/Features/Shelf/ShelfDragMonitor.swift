import AppKit
import Foundation

/// Watches for a drag starting anywhere on the Mac.
///
/// **Needs no permission**, which is what keeps the Shelf's promise intact. Per Apple's *Monitoring
/// Events* documentation, a global monitor may only observe **key** events with Accessibility
/// granted — the restriction is specific to keyboards. Mouse monitoring carries no such condition,
/// and this watches nothing but the mouse.
///
/// That distinction is the entire reason this class can exist. If it ever needs a key event, it
/// stops being permission-free and the Shelf's description stops being true.
@MainActor
final class ShelfDragMonitor {
    private var monitor: Any?
    private var session = ShelfDragSession()

    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?

    /// The drag pasteboard is what separates a real drag from the pointer merely moving with the
    /// button down — a text selection produces identical mouse events.
    private var dragChangeCount: Int { NSPasteboard(name: .drag).changeCount }

    func start() {
        guard monitor == nil else { return }
        // Seeded, so a drag that happened before the Shelf was switched on can't look new.
        session.begin(withChangeCount: dragChangeCount)

        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return }
            let event: ShelfDragSession.Event = event.type == .leftMouseUp
                ? .mouseUp
                : .mouseDragged(changeCount: self.dragChangeCount)

            switch self.session.handle(event) {
            case .dragBegan: self.onDragBegan?()
            case .dragEnded: self.onDragEnded?()
            case nil: break
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        session.reset()
    }

    var isDragInProgress: Bool { session.isInProgress }

    deinit {
        // A monitor outliving its owner keeps firing into a dead closure.
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
