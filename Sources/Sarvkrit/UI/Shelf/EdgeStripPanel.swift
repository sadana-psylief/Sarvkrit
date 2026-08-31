import AppKit

/// An invisible strip along a screen edge that reveals the shelf when a drag reaches it.
///
/// The whole permission story rests on this class. A window registered for dragged types is told by
/// AppKit when a drag passes over it — `draggingEntered` — so the shelf can react to a drag in
/// progress **without watching the mouse globally and therefore without Accessibility.** Every other
/// global gesture in this app goes through the event tap; this one does not have to.
final class EdgeStripPanel: NSPanel {
    private let onDragEntered: () -> Void

    init(frame: NSRect, onDragEntered: @escaping () -> Void) {
        self.onDragEntered = onDragEntered
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        // Above ordinary windows so a drag over another app still reaches it.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        // Clicks must pass straight through — an invisible strip down the side of the screen that
        // swallowed clicks would be indistinguishable from the Mac being broken. Dragging is
        // unaffected: `ignoresMouseEvents` does not disable dragging destinations.
        ignoresMouseEvents = true

        contentView = EdgeStripView(onDragEntered: onDragEntered)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The drag destination itself.
private final class EdgeStripView: NSView {
    private let onDragEntered: () -> Void

    init(onDragEntered: @escaping () -> Void) {
        self.onDragEntered = onDragEntered
        super.init(frame: .zero)
        // Everything a shelf can hold. Registering broadly is deliberate: the strip only *reveals*
        // the shelf, and the shelf itself decides what it can actually accept.
        registerForDraggedTypes([
            .fileURL, .URL, .string, .rtf, .png, .tiff,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered()
        // `.generic` rather than `.copy`: the strip is not the drop target, it just opens the shelf.
        // Claiming `.copy` here would let a drop land on the strip and vanish.
        return .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {}

    /// Refuse the drop itself. The shelf that just appeared is what should receive it.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
