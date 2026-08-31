import AppKit
import SwiftUI

/// The translucent outline showing where a dragged window will land.
///
/// A non-activating panel, because taking focus mid-drag would end the drag it is illustrating,
/// and `ignoresMouseEvents` for the same reason — an overlay under the pointer that accepted
/// events would eat the drop.
final class FootprintPanel {
    private let panel: NSPanel
    private let hosting: NSHostingView<FootprintView>

    init() {
        hosting = NSHostingView(rootView: FootprintView())
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        // Above ordinary windows but below the menu bar, so it reads as an overlay on the desktop
        // rather than as a window in the stack.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
    }

    /// Called when a drag arms, so the first show isn't also paying for the panel's very first
    /// layout pass while the pointer is already waiting on it.
    func prepare() {
        hosting.layoutSubtreeIfNeeded()
    }

    /// - Parameter rect: in Cocoa screen coordinates, exactly the rect the drop will apply.
    func show(_ rect: CGRect, animated: Bool) {
        // The root view is set once, at init, and deliberately not rebuilt here. It was being
        // replaced on every call by analogy with the clipboard picker's stale-content bug, but the
        // analogy doesn't hold: this view is a fixed coloured rectangle whose content never varies,
        // so rebuilding it only bought a SwiftUI layout pass per zone change during a drag.
        if panel.isVisible, animated {
            NSAnimationContext.runAnimationGroup { context in
                // Short enough to read as the footprint following the pointer rather than
                // catching up with it.
                context.duration = 0.07
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else {
            panel.setFrame(rect, display: true)
            panel.orderFrontRegardless()   // never `makeKey` — that would steal the drag
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
}

private struct FootprintView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
            )
            .padding(2)
    }
}
