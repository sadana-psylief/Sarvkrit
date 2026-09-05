import AppKit

/// Holds a window's real content view at its own natural height, against the top edge.
///
/// Exists for one reason: **`NSHostingView` centres its root when the view is taller than the
/// root wants to be.** Measured, a 350pt SwiftUI root sat 92pt down inside a 533pt host — exactly
/// half the difference. That is harmless while a window is always exactly as tall as its content,
/// and it is the whole problem the moment one is animated, because an animated resize means the
/// window and its content are different heights for every frame of it. Half the difference appears
/// as a blank band above the content, or eats the header when the window is the shorter of the two.
///
/// The tempting fix is on the SwiftUI side — make the root fill its bounds and align it to the top.
/// It cannot be done for a `MenuBarExtra` panel, which sizes *and positions* its own window from
/// what the root will accept; see `MenuBarWindowProbe` for the two ways that fails. So the root is
/// left exactly as SwiftUI wants it and this sits between it and the window instead: the window
/// resizes, this view resizes with it, and the content inside simply does not move.
///
/// Sizing is forwarded rather than invented, so inserting this changes nothing about how big
/// anyone thinks the window should be — only where the content sits inside it.
final class TopPinnedContentView: NSView {

    /// The view this was interposed in front of — the window's original content view.
    private(set) var content: NSView?

    /// The height `content` is laid out at, independent of how tall this view currently is.
    ///
    /// Set from the same measurement that drives the window's height, rather than read back from
    /// the content: during a resize the two disagree on purpose, and asking the content how tall
    /// it is mid-animation is how the disagreement leaks back in.
    var contentHeight: CGFloat = 0 {
        didSet {
            guard abs(contentHeight - oldValue) > 0.5 else { return }
            needsLayout = true
        }
    }

    /// Interposes a new instance between `window` and its current content view, once.
    ///
    /// Returns the existing one if it is already installed, so this is safe to call on every pass
    /// through the probe's `viewDidMoveToWindow`.
    @discardableResult
    static func install(in window: NSWindow) -> TopPinnedContentView? {
        if let existing = window.contentView as? TopPinnedContentView { return existing }
        guard let content = window.contentView else { return nil }

        let container = TopPinnedContentView(frame: content.frame)
        container.autoresizingMask = [.width, .height]
        // Order matters: taking the content view off the window first would let AppKit install a
        // fresh empty one and resize the old view on the way out.
        window.contentView = container
        container.addSubview(content)
        container.content = content
        container.contentHeight = content.fittingSize.height
        return container
    }

    override func layout() {
        super.layout()
        guard let content else { return }

        // Never taller than the window, or a grow would draw content above the title area; never
        // shorter than what it was measured at, or the content squeezes as the window animates.
        let height = contentHeight > 0 ? contentHeight : bounds.height
        content.frame = NSRect(
            x: 0,
            // AppKit's origin is bottom-left, so "pinned to the top" is an origin that moves.
            y: isFlipped ? 0 : bounds.height - height,
            width: bounds.width,
            height: height
        )
    }

    /// Forwarded, so interposing this cannot change anyone's idea of how big the window should be.
    override var fittingSize: NSSize { content?.fittingSize ?? super.fittingSize }
    override var intrinsicContentSize: NSSize { content?.intrinsicContentSize ?? super.intrinsicContentSize }
    override func hitTest(_ point: NSPoint) -> NSView? { content?.hitTest(point) }
}
