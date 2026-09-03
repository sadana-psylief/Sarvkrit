import AppKit
import SwiftUI

/// Owns the full window explicitly rather than using a SwiftUI `Window` scene.
///
/// In an `LSUIElement` app the window's lifecycle is genuinely custom: it starts closed, has
/// to reopen on demand from the menu *and* from a second launch, and closing it must not
/// quit the app. An `NSWindowController` makes all three one line each, where the SwiftUI
/// scene route depends on `openWindow` being reachable from contexts an agent app doesn't have.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show() {
        let state = AppState.shared

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Theme.Size.windowDefault),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Sarvkrit"
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: MainWindowView().environmentObject(state)
            )
            window.setContentSize(Theme.Size.windowDefault)
            window.contentMinSize = Theme.Size.windowMin
            window.center()
            window.setFrameAutosaveName("SarvkritMainWindow")
            window.delegate = self
            self.window = window
        }

        // Become a regular app for as long as the window is up. This is not only about the
        // Dock icon: an .accessory app cannot fully activate, so its windows never reliably
        // take key focus — they appear, then ignore clicks and typing. Must happen *before*
        // activate(), or the activation applies to the old policy.
        //
        // Through the lease rather than directly, because the editor windows need the same thing:
        // an unconditional drop on close would put the app back to .accessory while an editor was
        // still open, and that editor would stop accepting input for no visible reason.
        if !isShowing {
            isShowing = true
            ActivationPolicyLease.shared.acquire()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Tracks whether this window currently holds a lease, so showing an already-open window
    /// doesn't take a second one it will never give back.
    private var isShowing = false

    /// Back to a menu bar app once the last window is gone: no Dock icon, no app menu.
    func windowWillClose(_ notification: Notification) {
        guard isShowing else { return }
        isShowing = false
        ActivationPolicyLease.shared.release()
    }

    /// Keep the window object around after closing. Rebuilding the SwiftUI hosting view on
    /// every reopen would throw away scroll position and sidebar selection for no reason.
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
}
