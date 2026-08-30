import AppKit
import SwiftUI

/// A brief message at the top of the screen, like the system's volume and brightness HUD.
///
/// Two properties do the real work here, and both are easy to omit:
/// `canBecomeKey` stays false so it never steals focus from the app the user is working in, and
/// `ignoresMouseEvents` is true so a toast sitting over content doesn't silently swallow a click
/// aimed at the window beneath it.
final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private var panel: ToastPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private static let visibleDuration: TimeInterval = 1.6
    /// Below the menu bar, where macOS puts its own HUDs.
    private static let topMargin: CGFloat = 90

    func show(_ message: String, symbolName: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(rootView: ToastView(message: message, symbolName: symbolName))
        panel.layoutIfNeeded()
        panel.setContentSize(panel.contentView?.fittingSize ?? CGSize(width: 220, height: 44))
        position(panel)
        panel.orderFrontRegardless()

        // Re-arm rather than stack: a second toast replaces the first instead of queueing behind it.
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    private func makePanel() -> ToastPanel {
        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Click-through. Without it a toast over a Finder window eats the next click.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func position(_ panel: ToastPanel) {
        // The screen the pointer is on — which is the one the user is working on.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - Self.topMargin
        ))
    }
}

private struct ToastView: View {
    let message: String
    let symbolName: String

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
