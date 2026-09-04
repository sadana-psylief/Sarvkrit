import AppKit
import OSLog
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
        wirePinToScreen()
        // Installed unconditionally, before anything can put a window on screen. This is the one
        // shortcut that must never be missing when it is needed.
        CaptureOverlayGuard.shared.install()
        reconcileKeepAwake()

        guard !AppState.shared.hasCompletedOnboarding else { return }
        MainWindowController.shared.show()
    }

    /// The `sarvkrit://` URL scheme.
    ///
    /// On the delegate rather than as SwiftUI's `.onOpenURL`, which needs a window scene to
    /// attach to — this app has no window most of the time, and a scheme that only works while
    /// Settings happens to be open is worse than none.
    ///
    /// `open sarvkrit://…` against a running copy arrives here as an Apple Event, so
    /// `LSMultipleInstancesProhibited` is not in the way.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = CaptureURLCommand.parse(url) else {
                Self.urlLog.error("ignored \(url.absoluteString, privacy: .public)")
                continue
            }
            Self.urlLog.info("\(command.name, privacy: .public) via URL")
            switch command {
            case .cancel:
                CaptureOverlayGuard.shared.dismissEverything()
            case .capturePreviousArea:
                guard let screenshots = AppState.shared.features
                    .compactMap({ $0 as? ScreenshotFeature }).first else { return }
                Task { @MainActor in
                    await Self.capture(.area, with: screenshots,
                                       reopeningLastSelection: true)
                }
            case .openAnnotate(let file):
                openEditor(with: file)
            case .openFromClipboard:
                openEditorFromClipboard()
            case .openSettings:
                MainWindowController.shared.show()
            case .action(let action):
                guard let screenshots = AppState.shared.features
                    .compactMap({ $0 as? ScreenshotFeature }).first else { return }
                screenshots.perform(action)
            case .captureRect(let rect, let displayIndex):
                guard let screenshots = AppState.shared.features
                    .compactMap({ $0 as? ScreenshotFeature }).first else { return }
                Task { @MainActor in
                    await Self.captureRect(rect, displayIndex: displayIndex, with: screenshots)
                }
            }
        }
    }

    /// Opens an image in the editor, defaulting to the newest capture.
    private func openEditor(with file: URL?) {
        guard let screenshots = AppState.shared.features
            .compactMap({ $0 as? ScreenshotFeature }).first else { return }
        let url = file ?? screenshots.store.items.first.map { screenshots.store.url(for: $0) }
        guard let url else {
            ToastPresenter.shared.show("No capture to annotate yet",
                                       symbolName: "photo.on.rectangle")
            return
        }
        do {
            try ScreenshotEditorController.shared.open(fileURL: url)
        } catch {
            Self.urlLog.error("open-annotate failed: \(String(describing: error), privacy: .public)")
            ToastPresenter.shared.show("Couldn't open that image", symbolName: "exclamationmark.triangle")
        }
    }

    private func openEditorFromClipboard() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?
            .compactMap({ $0 as? NSImage }).first,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            ToastPresenter.shared.show("No image on the clipboard", symbolName: "doc.on.clipboard")
            return
        }
        ScreenshotEditorController.shared.open(image: cgImage)
    }

    private static let urlLog = Logger(subsystem: AppIdentity.logSubsystem, category: "URLScheme")
    private static let captureLog = Logger(subsystem: AppIdentity.logSubsystem, category: "Capture")

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
        // Belt and braces. Floating windows die with the process anyway, but quitting is exactly
        // the moment a user reaches for when something is stuck, and it must not leave anything
        // behind — including a hidden cursor.
        CaptureOverlayGuard.shared.dismissEverything()

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
        screenshots.showAllInOne = { [weak screenshots] in
            guard let screenshots else { return }
            MainActor.assumeIsolated {
                guard !AllInOneController.shared.isPresenting else {
                    AllInOneController.shared.dismiss()
                    return
                }
                Task { @MainActor in
                    await Self.allInOne(with: screenshots)
                }
            }
        }
        screenshots.showHistory = {
            MainActor.assumeIsolated { CaptureHistoryWindowController.shared.toggle() }
        }
        screenshots.pinClipboardImage = {
            MainActor.assumeIsolated { Self.pinClipboardOrUnlock() }
        }
        screenshots.recognizeText = { [weak screenshots] in
            guard let screenshots else { return }
            Task { @MainActor in await Self.capture(.textRecognition, with: screenshots) }
        }
        screenshots.captureScrolling = { [weak screenshots] in
            guard let screenshots else { return }
            Task { @MainActor in await Self.capture(.scrolling, with: screenshots) }
        }
        screenshots.restoreLastOverlay = {
            MainActor.assumeIsolated { QuickAccessController.shared.restoreLastClosed() }
        }
        screenshots.hideOverlays = {
            MainActor.assumeIsolated { QuickAccessController.shared.hideAll() }
        }

        // Pinning from the overlay, if the Pin feature exists. Wired through a closure so the
        // Screenshots feature knows nothing about pinned windows.
        QuickAccessController.shared.pinToScreen = { [weak screenshots] item in
            guard let screenshots,
                  let image = NSImage(contentsOf: screenshots.store.url(for: item)) else { return }
            MainActor.assumeIsolated {
                PinnedShotController.shared.pin(image: image, sourceRect: item.sourceRect)
            }
        }

        // The editor half. Until this is wired the Annotate button is hidden rather than present
        // and inert — a nil closure is how an absent half is absent.
        QuickAccessController.shared.openEditor = { [weak screenshots] item in
            guard let screenshots else { return }
            MainActor.assumeIsolated {
                guard let data = try? Data(contentsOf: screenshots.store.url(for: item)),
                      let contents = try? CaptureDocumentFile.decode(data) else { return }
                ScreenshotEditorController.shared.open(
                    image: contents.base ?? contents.flattened,
                    document: contents.document,
                    historyItemID: item.id)
            }
        }
        // Saving an edit rewrites the history entry in place rather than adding a second one:
        // the store is the sole writer of that directory, and the overlay and the history row are
        // both pointing at this id while the edit happens.
        ScreenshotEditorController.shared.commitEdit = { [weak screenshots] image, id in
            guard let screenshots, let id else { return }
            MainActor.assumeIsolated { _ = screenshots.store.replaceImage(of: id, with: image) }
        }

        CaptureHistoryWindowController.shared.store = screenshots.store
        CaptureHistoryWindowController.shared.openEditor = QuickAccessController.shared.openEditor
        CaptureHistoryWindowController.shared.pinToScreen = QuickAccessController.shared.pinToScreen

        QuickAccessController.shared.store = screenshots.store
        QuickAccessController.shared.corner = screenshots.quickAccessCorner
        QuickAccessController.shared.autoCloseAfter = screenshots.quickAccessAutoClose
    }

    @MainActor
    private static func capture(_ mode: CaptureMode,
                                with feature: ScreenshotFeature,
                                timerSeconds: Int = 0,
                                memory: CaptureModeMemory? = nil,
                                showsBarImmediately: Bool = false,
                                reopeningLastSelection: Bool = false) async {
        // Pressing the shortcut again while the overlay is up should dismiss it, not stack a
        // second full-screen overlay on top of the first.
        if CaptureOverlayController.shared.isPresenting {
            CaptureOverlayController.shared.dismiss()
            return
        }
        // Pressing the scrolling shortcut again finishes the capture in progress, which is a more
        // useful second press than starting a competing session.
        if ScrollCaptureSession.shared.isRunning {
            ScrollCaptureSession.shared.finish()
            return
        }

        do {
            let options = feature.captureOptions

            // The modes aimed by dragging all go down one path, which is also the path that puts
            // the confirm bar on screen. `deliver` uses the mode that came *back*, not the one
            // that went in: the bar can change it mid-capture, and delivering as the original
            // would file a text lookup as a screenshot.
            if mode.aimsByDragging {
                var chosen = memory ?? feature.modeMemory
                chosen.mode = mode
                let (result, finalMode) = try await CaptureSession.captureInteractive(
                    startingMode: mode,
                    memory: chosen,
                    timerSeconds: timerSeconds,
                    showsBarImmediately: showsBarImmediately,
                    initialSelection: reopeningLastSelection ? feature.lastSelection : nil,
                    choosesWindowFromList: feature.choosesWindowFromList,
                    using: feature.capturer,
                    options: options,
                    chrome: feature.overlayChrome,
                    onChoice: { memory, seconds in
                        feature.modeMemory = memory
                        feature.selfTimerSeconds = seconds
                    })
                guard let result else { return }
                // Remembered so it can be retaken. Only a real capture updates it — a cancelled
                // one must not overwrite the rect the user still wants back.
                if let rect = result.sourceRect { feature.lastSelection = rect }
                deliver(result, mode: finalMode, with: feature)
                return
            }

            let result: CaptureSession.Result?
            switch mode {
            case .window:
                result = try await CaptureSession.captureWindow(
                    using: feature.capturer, options: options,
                    fromList: feature.choosesWindowFromList)
            default:
                result = try await CaptureSession.captureFullscreen(using: feature.capturer,
                                                                    options: options)
            }
            // Cancelling is an ordinary outcome, not a failure — no toast.
            guard let result else { return }
            deliver(result, mode: mode, with: feature)
        } catch {
            // Logged as well as shown. A toast tells the user something went wrong; only this says
            // *what*, and "the screenshot shortcut does nothing" is unanswerable without it.
            captureLog.error("capture \(String(describing: mode), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            reportFailure()
        }
    }

    @MainActor
    private static func deliver(_ result: CaptureSession.Result,
                                mode: CaptureMode,
                                with feature: ScreenshotFeature) {
        let plan = CaptureDestination.plan(for: mode, settings: feature.destinationSettings)

        // Text recognition's output is text, not a picture — filing a PNG of it would leave junk
        // in the capture folder after every lookup. `CaptureDestination` already routes it to the
        // pasteboard alone; this is what it puts there.
        if mode == .textRecognition {
            deliverRecognisedText(from: result.image)
            return
        }

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
    private static func deliverRecognisedText(from image: CGImage) {
        let recognised = TextRecognizer.recognize(image)
        let text = recognised.text

        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            TextResultController.shared.show(text: text, isBarcode: false)
            return
        }

        if let code = recognised.barcodes.first {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.payload, forType: .string)
            // The payload goes to the pasteboard and stops there. Opening a URL scanned off the
            // screen automatically is a phishing vector — a person has to choose to follow it,
            // which is what the panel's "Open Link" button is and why it is only ever an offer.
            TextResultController.shared.show(text: code.payload, isBarcode: true)
            return
        }

        ToastPresenter.shared.show("No text found", symbolName: "text.viewfinder")
    }

    @MainActor
    /// A rect handed over by a script: capture it and deliver it like any other capture.
    private static func captureRect(_ rect: CGRect, displayIndex: Int?,
                                    with feature: ScreenshotFeature) async {
        do {
            guard let result = try await CaptureSession.captureRect(
                rect, displayIndex: displayIndex, pointer: NSEvent.mouseLocation,
                using: feature.capturer,
                options: feature.captureOptions) else { return }
            // `.area`, because that is what it is — the same destination rules, the same history
            // entry, the same overlay afterwards. Only the aiming was different.
            deliver(result, mode: .area, with: feature)
        } catch {
            captureLog.error("capture rect failed: \(String(describing: error), privacy: .public)")
            reportFailure()
        }
    }

    /// One shortcut, every mode — the same interactive capture, with the bar up before anything
    /// is drawn, because choosing the mode is the point of this one.
    private static func allInOne(with feature: ScreenshotFeature) async {
        // Pressing it again while it is up puts it away rather than stacking a second one.
        if CaptureOverlayController.shared.isPresenting || AllInOneController.shared.isPresenting {
            AllInOneController.shared.dismiss()
            CaptureOverlayController.shared.dismiss()
            return
        }
        let remembered = feature.modeMemory
        await capture(remembered.mode.aimsByDragging ? remembered.mode : .area,
                      with: feature,
                      timerSeconds: feature.selfTimerSeconds,
                      memory: remembered,
                      showsBarImmediately: true)
    }

    /// Unlock everything if anything is locked; otherwise pin whatever image is on the clipboard.
    ///
    /// Unlocking comes first and must: a locked pin takes no clicks, so this is the way out, and
    /// letting the pinning behaviour shadow it would leave someone with a dead window and a
    /// shortcut that made another one.
    ///
    /// Lives here rather than on `PinToScreenFeature` because it has two callers now — that
    /// feature's ⌃⇧P, and `sarvkrit://pin`, which has to work whether or not the feature is on.
    @MainActor
    static func pinClipboardOrUnlock() {
        let controller = PinnedShotController.shared
        if controller.count > 0 {
            controller.unlockAll()
        }
        guard let image = NSPasteboard.general.readObjects(
            forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
            if controller.count == 0 {
                ToastPresenter.shared.show("No image on the clipboard to pin",
                                           symbolName: "pin.slash")
            }
            return
        }
        controller.pin(image: image, sourceRect: nil)
    }

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

    /// ⌃⇧P unlocks everything if anything is locked, and otherwise pins the clipboard image.
    ///
    /// Unlocking takes priority because a locked pin accepts no clicks, so this shortcut is the
    /// only way out of Lock Mode — letting the pinning behaviour shadow it would strand the user.
    private func wirePinToScreen() {
        guard let pin = AppState.shared.features
            .compactMap({ $0 as? PinToScreenFeature }).first else { return }

        pin.pinFromClipboardOrUnlock = {
            MainActor.assumeIsolated { Self.pinClipboardOrUnlock() }
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
