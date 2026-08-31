import AppKit

/// An invisible strip along a screen edge that reveals the shelf when a drag reaches it.
///
/// A window registered for dragged types is told by AppKit when a drag passes over it —
/// `draggingEntered` — so the shelf can react without watching the mouse globally.
///
/// **The strip is only live while a drag is actually in progress**, and that is not a refinement,
/// it is the fix for two bugs at once:
///
/// - The first version set `ignoresMouseEvents = true` permanently, under a comment claiming
///   dragging was unaffected. **That was wrong.** A window ignoring mouse events passes them to the
///   window behind it, and drag-destination callbacks never fire — so the strip never worked.
/// - But a strip that *doesn't* ignore mouse events swallows every click along a whole screen edge,
///   which reads as the Mac being broken rather than as a bug in this app.
///
/// Arming it only for the duration of a drag is what satisfies both. `ShelfDragMonitor` decides
/// when.
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
        // Inert until a drag begins. See the type's comment: live, it eats clicks; ignoring mouse
        // events, it can't receive drags either.
        ignoresMouseEvents = true

        contentView = EdgeStripView(onDragEntered: onDragEntered)
    }

    /// Live for the duration of a drag, inert the rest of the time.
    func setArmed(_ armed: Bool) {
        ignoresMouseEvents = !armed
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
