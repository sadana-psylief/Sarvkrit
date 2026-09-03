import AppKit
import OSLog
import SwiftUI

/// Hands the enclosing `NSWindow` to a callback, and reports its own height as SwiftUI lays it out.
///
/// `MenuBarExtra` vends no window reference, so this is the only way to reach the panel's window.
/// Installed as a `.background` of the dropdown's content: a background takes the size of what it
/// backs without contributing any of its own, so the probe cannot perturb the layout it exists to
/// stabilise. `hitTest` returns nil for the same reason `ShelfDragSource` does the opposite — that
/// view wants clicks, this one must never take one out of the padding.
struct MenuBarWindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        view.onHeight = onHeight
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onWindow = onWindow
        view.onHeight = onHeight
    }

    final class ProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        var onHeight: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }

        /// The content's height, straight from SwiftUI's own layout pass — which is not necessarily
        /// the window's height, and the difference is the thing worth knowing.
        override func layout() {
            super.layout()
            onHeight?(bounds.height)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Keeps the tray panel the size of its content, with its top edge under the menu bar icon.
///
/// **What actually goes wrong, measured rather than assumed.** A `MenuBarExtra` window is
/// positioned by the system once, at presentation. When the content *grows* SwiftUI handles it
/// correctly — it drops the origin and holds the top edge exactly where the system put it. When the
/// content *shrinks* SwiftUI does nothing at all: no `NSWindowDidResizeNotification` is posted, the
/// window keeps the tallest height it reached during that presentation, and the smaller content is
/// centred inside it. One instrumented tab switch, Sound → Keyboard:
///
///     grow    frame={{731, 628}, {420, 319}}  top=947  content=319
///     grow    frame={{731, 522}, {420, 425}}  top=947  content=425
///     grow    frame={{731, 438}, {420, 509}}  top=947  content=509
///     shrink  frame={{731, 438}, {420, 509}}  top=947  content=266   ← no resize
///     shrink  frame={{731, 438}, {420, 509}}  top=947  content=319   ← no resize
///
/// So the panel never came unmoored: the window's top edge was under the icon the whole time. What
/// the user sees floating in the middle of the screen is the material drawn around 266pt of content
/// centred in a 509pt window — which is why an earlier attempt to fix this by adjusting the origin
/// could not have worked, and why the height has to be driven from the *content*, not from a resize
/// notification that never arrives.
@MainActor
final class MenuBarWindowAnchor {
    static let shared = MenuBarWindowAnchor()

    /// Kept because this corrects a window SwiftUI owns, on undocumented behaviour that has changed
    /// between macOS releases before. When it stops working, this line is the difference between
    /// "the panel is broken again" and knowing which half.
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "TrayPanel")

    /// Weak: the panel's window belongs to SwiftUI, and outliving it is not this object's business.
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// The top edge the system chose for this presentation. Captured when the panel appears and
    /// held until it goes away — never re-read from a frame that has already been resized, because
    /// an anchor latched from a drifted frame pins the panel to the wrong place for as long as it
    /// stays open.
    private var anchorTop: CGFloat?
    /// SwiftUI's own idea of how tall the content is, straight from the probe's layout pass.
    private var contentHeight: CGFloat = 0
    /// Set while *we* are the ones resizing, so the `didResize` that follows can't recurse.
    private var isAdjusting = false

    private init() {}

    /// Idempotent: the probe reports its window on every pass through `viewDidMoveToWindow`.
    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }

        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        self.window = window
        anchorTop = nil

        guard let window else { return }

        observe(NSWindow.didChangeOcclusionStateNotification, on: window) { [weak self] in
            guard let self, let window = self.window else { return }
            if window.occlusionState.contains(.visible) {
                self.captureAnchor()
                self.pin()
            } else {
                self.anchorTop = nil
            }
        }
        // A second chance to capture, for the presentation where the occlusion notification lands
        // before the system has finished positioning the window.
        observe(NSWindow.didBecomeKeyNotification, on: window) { [weak self] in
            self?.captureAnchor()
        }
        // Deliberately *not* a presentation-end signal: this fires while the panel is open and
        // still on screen — toggling a switch inside it is enough — and clearing the anchor there
        // would throw away the one number worth keeping.
        observe(NSWindow.willCloseNotification, on: window) { [weak self] in
            self?.anchorTop = nil
        }
        // Growth still arrives this way. Cheap to honour, and it keeps the two paths in agreement.
        observe(NSWindow.didResizeNotification, on: window) { [weak self] in
            self?.pin()
        }

        captureAnchor()
    }

    /// The content's height, reported by the probe as SwiftUI lays it out. **This is the trigger
    /// that matters:** it is the only signal a shrink produces.
    func note(contentHeight height: CGFloat) {
        guard abs(height - contentHeight) > MenuBarPanelPlacement.moveTolerance else { return }
        contentHeight = height
        pin()
    }

    private func observe(
        _ name: Notification.Name, on window: NSWindow, _ handler: @escaping () -> Void
    ) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated(handler)
            }
        )
    }

    private func captureAnchor() {
        guard anchorTop == nil, let window, window.isVisible,
              let visible = screen(for: window)?.visibleFrame else { return }

        let top = window.frame.maxY
        guard MenuBarPanelPlacement.isPlausibleAnchor(top: top, menuBarBottom: visible.maxY) else {
            log.debug("anchor rejected: top=\(top, privacy: .public) visibleMaxY=\(visible.maxY, privacy: .public)")
            return
        }
        anchorTop = top
    }

    private func pin() {
        guard !isAdjusting, contentHeight > 0, let window, window.isVisible,
              let visible = screen(for: window)?.visibleFrame else { return }

        let current = window.frame
        let size = CGSize(width: current.width, height: contentHeight)
        let origin = MenuBarPanelPlacement.origin(
            forHeight: contentHeight,
            x: current.minX,
            top: anchorTop ?? visible.maxY,
            width: size.width,
            in: visible
        )

        guard abs(current.height - size.height) > MenuBarPanelPlacement.moveTolerance
                || MenuBarPanelPlacement.needsMove(from: current.origin, to: origin) else { return }

        // One `setFrame`, not `setContentSize` followed by `setFrameTopLeftPoint` the way
        // `ClipboardPickerController.resize(to:)` does it. That panel opens at the cursor and is
        // never visibly wrong in between; here the in-between state — the new short height still
        // sitting on the old bottom-left origin — is precisely the bug, and it would flash.
        isAdjusting = true
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        isAdjusting = false

        log.debug("""
            pinned \(NSStringFromRect(current), privacy: .public) -> \
            \(NSStringFromRect(window.frame), privacy: .public) \
            anchorTop=\(self.anchorTop ?? -1, privacy: .public)
            """)
    }

    /// The screen holding the status item, which is the one the window is on — not
    /// `ScreenPlacement.screenUnderPointer`, whose answer is about the pointer and would be the
    /// wrong display the moment someone opens this panel and moves the mouse away.
    private func screen(for window: NSWindow) -> NSScreen? {
        window.screen
            ?? NSScreen.screens.first { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.maxY)) }
            ?? NSScreen.main
    }
}
