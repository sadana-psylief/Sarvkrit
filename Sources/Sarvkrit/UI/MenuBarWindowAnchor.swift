import AppKit
import OSLog
import SwiftUI

/// Hands the enclosing `NSWindow` to a callback, and reports its own height as SwiftUI lays it out.
///
/// **Why the panel snaps between sizes instead of animating, which is not for want of trying.**
/// An animated window resize needs the window and its content to be different heights for the
/// duration, and SwiftUI *centres* a root that does not fill its bounds — measured, a 350pt root
/// sat 92pt down inside a 533pt host, exactly half the difference. So every frame of an animation
/// would show a blank band above the content, or clip the header when the window is the shorter of
/// the two.
///
/// The obvious fix is to make the root fill the window and pin the content to the top. It cannot
/// be done from in here: `MenuBarExtra` sizes *and positions* its own window from what the root
/// will accept, and a root that accepts anything breaks it two different ways, both measured:
///
///   - `.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)` — the panel was created
///     **10pt tall**, the system placed that, and it opened in the middle of the screen with the
///     content hanging outside the material. Naming an explicit `idealHeight` does not help, so
///     the size is taken from the *minimum*, not the ideal.
///   - `.frame(maxHeight: .infinity, alignment: .top)` — created at the right size, but SwiftUI
///     then settled on a height this probe disagreed with and re-asserted it indefinitely: the
///     window held at 400pt around 363pt of content, corrected and undone every couple of seconds.
///
/// Neither shows up in a `fittingSize` test, because the *ideal* height is right in both cases.
/// The panel's root is therefore left exactly as SwiftUI sizes it, and nothing may be layered
/// outside it. Animating this properly means owning the window — an `NSStatusItem` and our own
/// `NSPanel`, the way `ShelfPanel` and `ClipboardPickerPanel` already do it — not a modifier.
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
    /// Keeps the content still while the window resizes around it. Weak for the same reason.
    private weak var pinned: TopPinnedContentView?
    private var observers: [NSObjectProtocol] = []

    /// The top edge the system chose for this presentation. Captured when the panel appears and
    /// held until it goes away — never re-read from a frame that has already been resized, because
    /// an anchor latched from a drifted frame pins the panel to the wrong place for as long as it
    /// stays open.
    private var anchorTop: CGFloat?
    /// SwiftUI's own idea of how tall the content is, straight from the probe's layout pass.
    private var contentHeight: CGFloat = 0
    /// Set while *we* are the ones resizing, so the `didResize` that follows can't recurse.
    ///
    /// Worth knowing that this guards less than it looks: the observers below are registered with
    /// `queue: .main`, which delivers on the main *operation queue* and so a runloop turn later
    /// than the `setFrame` that caused it — by which point a flag cleared synchronously is already
    /// false. Harmless today, because the `didResize` that gets through finds the window already
    /// where it belongs and does nothing. Anything that ever holds the window away from the
    /// content height, an animation above all, would need a flag that spans the whole operation.
    private var isAdjusting = false
    /// Set between a content report and the coalesced pass that acts on it.
    private var pinScheduled = false
    /// The height the last completed step left the window at. `0` means this presentation has not
    /// placed the panel yet, which is what stops it animating open.
    private var settledHeight: CGFloat = 0
    /// Where a running animation is heading, if one is running.
    private var inFlightTo: CGRect?
    /// Bumped per animation, so a superseded one's completion handler knows it no longer owns the
    /// state. A `MenuBarExtra` panel is reused for the life of the app, so state stuck here does
    /// not clear itself.
    private var generation = 0

    private func reset() {
        generation += 1
        inFlightTo = nil
        isAdjusting = false
        settledHeight = 0
    }

    private init() {}

    /// Idempotent: the probe reports its window on every pass through `viewDidMoveToWindow`.
    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }

        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        self.window = window
        anchorTop = nil
        reset()

        guard let window else { return }

        // Interposed once, before anything is measured or moved. Without it an animated resize
        // shows half its own height difference as blank space above the content.
        pinned = TopPinnedContentView.install(in: window)

        observe(NSWindow.didChangeOcclusionStateNotification, on: window) { [weak self] in
            guard let self, let window = self.window else { return }
            if window.occlusionState.contains(.visible) {
                self.captureAnchor()
                self.pin()
            } else {
                self.anchorTop = nil
                self.reset()
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
            self?.reset()
        }
        // Growth still arrives this way. Cheap to honour, and it keeps the two paths in agreement.
        observe(NSWindow.didResizeNotification, on: window) { [weak self] in
            // Ignored while we are the ones resizing: an animated resize posts one of these per
            // frame, and every one would otherwise re-enter and re-decide. To see those frames —
            // the only way to tell whether the window actually moved smoothly, since no test can
            // watch a window animate — log `window.frame` here.
            guard let self, !self.isAdjusting else { return }
            self.pin()
        }

        captureAnchor()
    }

    /// The content's height, reported by the probe as SwiftUI lays it out. **This is the trigger
    /// that matters:** it is the only signal a shrink produces.
    ///
    /// Records and defers rather than resizing on the spot, because this arrives from inside the
    /// probe's `layout()`. Resizing a window there changes the hosting view's bounds mid-layout
    /// and re-enters `layout()`; deferring means one correction per runloop turn however many
    /// layout passes a change produces.
    func note(contentHeight height: CGFloat) {
        guard abs(height - contentHeight) > MenuBarPanelPlacement.moveTolerance else { return }
        contentHeight = height
        // The container lays the content out at this height, not at the window's — during a
        // resize those differ on purpose.
        pinned?.contentHeight = height

        // Acted on **now**, inside the probe's layout pass, and not deferred to the next runloop
        // turn. On a grow SwiftUI has already resized the window to the settled height by the time
        // this arrives, and a turn's delay is long enough for that frame to be drawn: the panel
        // visibly snaps to full size and then animates from the top again.
        //
        // Resizing from inside `layout()` is only safe because of `TopPinnedContentView`. The
        // content's height no longer depends on the window's, so the re-entrant layout this
        // provokes measures the same height and returns at the tolerance check above. `pinScheduled`
        // is the guard that makes that terminate rather than a promise to run later.
        guard !pinScheduled else { return }
        pinScheduled = true
        pin()
        pinScheduled = false
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

    /// Decide, then do. Every judgement lives in `MenuBarPanelResize`; this half owns only the
    /// AppKit calls and the bookkeeping an animation needs.
    private func pin() {
        guard let window, window.isVisible,
              let visible = screen(for: window)?.visibleFrame else { return }

        apply(
            MenuBarPanelResize.step(
                window: window.frame,
                settledHeight: settledHeight,
                contentHeight: contentHeight,
                inFlightTo: inFlightTo,
                anchorTop: anchorTop ?? visible.maxY,
                visible: visible,
                // Read here, once, at the moment of deciding. Not the thing `Tokens.swift` warns
                // against: that warning is about reading it in a `View` body, where the value is
                // captured in a render and never updates again.
                animates: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ),
            to: window
        )
    }

    private func apply(_ step: MenuBarPanelResize.Step, to window: NSWindow) {
        switch step {
        case .none:
            return

        case .set(let frame):
            // One `setFrame`, not `setContentSize` followed by `setFrameTopLeftPoint` the way
            // `ClipboardPickerController.resize(to:)` does it. That panel opens at the cursor and
            // is never visibly wrong in between; here the in-between state — the new short height
            // still sitting on the old bottom-left origin — is precisely the bug, and it would
            // flash.
            let before = window.frame
            isAdjusting = true
            window.setFrame(frame, display: true)
            isAdjusting = false
            settledHeight = frame.height
            inFlightTo = nil
            log.debug("""
                set \(NSStringFromRect(before), privacy: .public) -> \
                \(NSStringFromRect(window.frame), privacy: .public) \
                anchorTop=\(self.anchorTop ?? -1, privacy: .public)
                """)

        case .animate(let from, let to):
            generation += 1
            let generation = self.generation
            isAdjusting = true
            inFlightTo = to
            // Recorded now rather than in the completion handler. A superseded animation's
            // completion bails at the generation check, and if the baseline were only written
            // there it would be left describing a height the panel has not been at for two
            // switches — enough for the next correction to animate to a place it already is.
            // Logged once as `350 350 363 363` followed by a second `animate 363 -> 350`.
            settledHeight = to.height

            // The rewind. On a grow SwiftUI has already jumped the window to the settled height by
            // the time the content report arrives, so without this the animation starts at its own
            // destination and there is nothing to see. `display: false` because this is not a
            // frame anyone should be shown — it is where the animation begins, and the animation
            // begins in the same call stack.
            if !MenuBarPanelResize.same(window.frame, from) {
                // `display: false` is not enough on its own — the frame still reaches the window
                // server, and on a 195pt grow that is a visible flash of the panel at its old
                // height. This holds the screen until the animation's first frame is in.
                window.disableScreenUpdatesUntilFlush()
                window.setFrame(from, display: false)
            }

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Theme.Motion.panelResizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // The whole rect in one call, which is what holds the top edge still: the origin
                // moves by Δy = −Δh, so y + h is constant at every step. Animating height and
                // origin as separate properties would let rounding wobble the top edge.
                window.animator().setFrame(to, display: true)
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // A newer switch may have started meanwhile; it owns the state now, and
                    // clearing `isAdjusting` here would unguard its animation.
                    guard let self, generation == self.generation else { return }
                    self.isAdjusting = false
                    self.inFlightTo = nil
                    // One settling pass: absorbs sub-pixel residue and anything SwiftUI did to the
                    // window while we were not listening.
                    self.pin()
                }
            })

            log.debug("""
                animate \(from.height, privacy: .public) -> \(to.height, privacy: .public) \
                top=\(to.maxY, privacy: .public) \
                anchorTop=\(self.anchorTop ?? -1, privacy: .public)
                """)
        }
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
