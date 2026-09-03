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
        wireScreenshots()
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
        AppState.shared.features
            .compactMap { $0 as? ScreenshotFeature }
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
        shelf.setEdgeStripsArmed = { armed in
            MainActor.assumeIsolated { ShelfController.shared.setEdgeStripsArmed(armed) }
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

    /// Fullscreen capture, wired the same way — the feature knows nothing about toasts or windows.
    ///
    /// The capture itself is async because ScreenCaptureKit is; the hotkey fires on the main
    /// thread and hands off to a Task rather than blocking it, since a capture of a large display
    /// takes long enough to be felt as a stutter if it ran inline.
    private func wireScreenshots() {
        guard let screenshots = AppState.shared.features
            .compactMap({ $0 as? ScreenshotFeature }).first else { return }

        screenshots.captureFullscreen = { [weak screenshots] in
            guard let screenshots else { return }
            Task { @MainActor in await Self.capture(.fullscreen, with: screenshots) }
        }
        screenshots.captureArea = { [weak screenshots] in
            guard let screenshots else { return }
            Task { @MainActor in await Self.capture(.area, with: screenshots) }
        }
        screenshots.captureWindow = { [weak screenshots] in
            guard let screenshots else { return }
            Task { @MainActor in await Self.capture(.window, with: screenshots) }
        }
        screenshots.restoreLastOverlay = {
            MainActor.assumeIsolated { QuickAccessController.shared.restoreLastClosed() }
        }
        screenshots.hideOverlays = {
            MainActor.assumeIsolated { QuickAccessController.shared.hideAll() }
        }

        QuickAccessController.shared.store = screenshots.store
        QuickAccessController.shared.corner = screenshots.quickAccessCorner
        QuickAccessController.shared.autoCloseAfter = screenshots.quickAccessAutoClose
    }

    @MainActor
    private static func capture(_ mode: CaptureMode, with feature: ScreenshotFeature) async {
        // Pressing the shortcut again while the overlay is up should dismiss it, not stack a
        // second full-screen overlay on top of the first.
        if CaptureOverlayController.shared.isPresenting {
            CaptureOverlayController.shared.dismiss()
            return
        }

        do {
            let options = feature.captureOptions
            let result: CaptureSession.Result?
            switch mode {
            case .area:
                result = try await CaptureSession.captureArea(using: feature.capturer,
                                                              options: options,
                                                              chrome: feature.overlayChrome)
            case .window:
                result = try await CaptureSession.captureWindow(using: feature.capturer,
                                                                options: options)
            default:
                result = try await CaptureSession.captureFullscreen(using: feature.capturer,
                                                                    options: options)
            }
            // Cancelling is an ordinary outcome, not a failure — no toast.
            guard let result else { return }
            deliver(result, mode: mode, with: feature)
        } catch {
            reportFailure()
        }
    }

    @MainActor
    private static func deliver(_ result: CaptureSession.Result,
                                mode: CaptureMode,
                                with feature: ScreenshotFeature) {
        let plan = CaptureDestination.plan(for: mode, settings: feature.destinationSettings)

        var item: CaptureHistoryItem?
        if plan.writesFile {
            item = feature.store.add(image: result.image, mode: mode,
                                     sourceRect: result.sourceRect,
                                     displayID: result.display?.displayID)
            guard item != nil else {
                ToastPresenter.shared.show("Couldn't save the screenshot",
                                           symbolName: "exclamationmark.triangle")
                return
            }
        }
        if plan.writesClipboard {
            CaptureWriter.copyToPasteboard(result.image)
        }

        // The overlay stands in for the toast when it is on — two confirmations of the same event
        // is one too many, and the overlay says more.
        if plan.showsOverlay, let item {
            let controller = QuickAccessController.shared
            controller.corner = feature.quickAccessCorner
            controller.autoCloseAfter = feature.quickAccessAutoClose
            controller.allowShowingAgain()
            controller.show(item)
            return
        }

        let verb = plan.writesFile && plan.writesClipboard ? "saved and copied"
                 : plan.writesFile ? "saved" : "copied"
        ToastPresenter.shared.show("Screenshot \(verb)", symbolName: "camera.viewfinder")
    }

    @MainActor
    private static func reportFailure() {
        // A denied grant arrives as `noDisplays`, not as a permission error — there is no
        // permission error to catch. If the preflight disagrees, the grant landed after launch and
        // only a relaunch can pick it up.
        let stale = ScreenRecordingRelaunch.looksLikeStaleGrant(
            preflightGranted: AppState.shared.permissions.canCaptureScreen,
            capturedDisplayCount: 0)
        ToastPresenter.shared.show(
            stale ? "Quit and reopen Sarvkrit to finish enabling screenshots"
                  : "Couldn't take a screenshot",
            symbolName: "exclamationmark.triangle")
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
