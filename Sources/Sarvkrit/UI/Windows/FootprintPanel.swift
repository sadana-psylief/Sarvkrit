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
        hosting = NSHostingView(rootView: FootprintView(isVisible: false))
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

    /// - Parameter rect: in Cocoa screen coordinates, exactly the rect the drop will apply.
    func show(_ rect: CGRect, animated: Bool) {
        // The root view is replaced rather than the panel rebuilt: a reused `NSHostingView` that
        // is never given fresh content is what once made the clipboard picker show stale entries.
        hosting.rootView = FootprintView(isVisible: true)

        if panel.isVisible, animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
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
    let isVisible: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
            )
            .opacity(isVisible ? 1 : 0)
            .padding(2)
    }
}
