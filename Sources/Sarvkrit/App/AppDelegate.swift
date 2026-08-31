import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// An LSUIElement app has no Dock icon and no window of its own, so a first launch would
    /// otherwise be completely silent: the user double-clicks the app they just installed and
    /// nothing happens except a new glyph quietly appearing in the menu bar. Show onboarding
    /// once, then stay out of the way on every later launch.
    func applicationDidFinishLaunching(_ notification: Notification) {
        observeDuplicateLaunches()
        wireClipboardPicker()
        wireShelf()
        wireCutPasteToasts()
        reconcileKeepAwake()

        guard !AppState.shared.hasCompletedOnboarding else { return }
        MainWindowController.shared.show()
    }

    /// Launching Sarvkrit while it's already running has to do *something* visible —
    /// especially when the menu bar icon is hidden, since re-launching is then the only way
    /// back in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    /// Closing the window must not quit: Sarvkrit's whole job happens in the background.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clipboard writes are coalesced onto a background queue so a copy never stalls the main
    /// thread. That trade is only safe if quitting waits for the last one — otherwise the most
    /// recent copies would be lost on the way out.
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.features
            .compactMap { $0 as? ClipboardFeature }
            .forEach { $0.store.flush() }
        AppState.shared.features
            .compactMap { $0 as? ShelfFeature }
            .forEach { $0.store.flush() }
    }

    /// Same closure-wiring as the clipboard picker, for the same reason: the feature never imports
    /// the UI layer.
    private func wireShelf() {
        guard let shelf = AppState.shared.features
            .compactMap({ $0 as? ShelfFeature }).first else { return }

        ShelfController.shared.configure(feature: shelf)
        shelf.showShelf = {
            MainActor.assumeIsolated { ShelfController.shared.show() }
        }
        shelf.installEdgeStrips = { edge, thickness in
            MainActor.assumeIsolated {
                ShelfController.shared.installEdgeStrips(on: edge, thickness: thickness)
            }
        }
        shelf.removeEdgeStrips = {
            MainActor.assumeIsolated { ShelfController.shared.removeEdgeStrips() }
        }
    }

    /// The clipboard feature raises the picker through a closure so it never has to know about the
    /// UI layer — the same separation that keeps `Feature` free of SwiftUI.
    private func wireClipboardPicker() {
        guard let clipboard = AppState.shared.features
            .compactMap({ $0 as? ClipboardFeature }).first else { return }

        ClipboardPickerController.shared.configure(feature: clipboard)
        clipboard.showPicker = {
            MainActor.assumeIsolated { ClipboardPickerController.shared.show() }
        }
    }

    /// Cut & Paste raises its confirmation through a closure, so the feature never imports SwiftUI.
    private func wireCutPasteToasts() {
        guard let cutPaste = AppState.shared.features
            .compactMap({ $0 as? CutPasteFeature }).first else { return }

        cutPaste.showToast = { message, symbol in
            MainActor.assumeIsolated { ToastPresenter.shared.show(message, symbolName: symbol) }
        }
    }

    /// Checks whether a system-wide sleep override survived from a previous session.
    ///
    /// Reading is free; clearing would cost a password, so this only ever *reports* — the pane
    /// offers a button. Firing an auth dialog at launch would be worse than the problem.
    private func reconcileKeepAwake() {
        AppState.shared.features
            .compactMap { $0 as? KeepAwakeFeature }
            .forEach { $0.reconcile() }
    }

    /// A second copy of Sarvkrit that started up, found us, and exited posts this on its way
    /// out. Reopening the app has to surface *something*, and we're the instance that survived.
    private func observeDuplicateLaunches() {
        DistributedNotificationCenter.default().addObserver(
            forName: AppIdentity.showWindowNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MainWindowController.shared.show() }
        }
    }
}
