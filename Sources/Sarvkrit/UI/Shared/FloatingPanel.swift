import AppKit

/// A borderless panel that floats above other windows.
///
/// Extracted because the capture overlay, the Quick Access overlay and pinned screenshots all
/// need the same eight lines of `NSPanel` setup with different answers — three callers, which is
/// the bar `ScreenPlacement`'s comment sets.
///
/// **Deliberately not adopted by `ShelfPanel`, `ToastPanel` or `EdgeStripPanel`.** Each of those
/// carries a documented deviation that took a bug to find — the Shelf not dismissing on resign-key,
/// the edge strip arming only during a drag — and rewiring three shipping panels to share a base
/// is risk with no payoff. If a fourth new caller appears, revisit.
class FloatingPanel: NSPanel {

    struct Style {
        var level: NSWindow.Level = .floating
        /// Whether the panel can take keyboard focus. False for anything purely decorative;
        /// **true for anything that needs Escape**, which is easy to forget until Escape does
        /// nothing and the overlay can't be dismissed.
        var acceptsKey = false
        /// `ignoresMouseEvents`. A panel with this on cannot be clicked *at all* — `ToastPanel`
        /// uses it so a HUD doesn't swallow a click aimed at the window beneath, and Pin's Lock
        /// Mode uses it as the actual feature.
        var clickThrough = false
        var joinsAllSpaces = true
        var hasShadow = true
        var isResizable = false
    }

    private let style: Style

    override var canBecomeKey: Bool { style.acceptsKey }
    /// Never main. A capture overlay or a pinned screenshot becoming the app's main window would
    /// make Sarvkrit look like a foreground app with a document open.
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, style: Style) {
        self.style = style
        var mask: NSWindow.StyleMask = [.nonactivatingPanel, .fullSizeContentView, .borderless]
        if style.isResizable { mask.insert(.resizable) }
        super.init(contentRect: contentRect, styleMask: mask, backing: .buffered, defer: false)

        // **Order matters, and getting it wrong is silent.** `isFloatingPanel = true` assigns
        // `.floating` (level 3) as a side effect, so setting the level first means the level is
        // thrown away. The capture overlay asks for the shielding level precisely so it covers the
        // menu bar; at 3 the menu bar stays live above a frozen screen — which is what was
        // happening, and it took listing the real window's `kCGWindowLayer` to see it, because a
        // frozen overlay showing the screen it just photographed looks correct either way.
        isFloatingPanel = true
        level = style.level
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = style.hasShadow
        isReleasedWhenClosed = false
        ignoresMouseEvents = style.clickThrough

        var behaviour: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .stationary]
        if style.joinsAllSpaces { behaviour.insert(.canJoinAllSpaces) }
        collectionBehavior = behaviour
    }
}
