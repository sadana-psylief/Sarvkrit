import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import os

/// Taking screenshots.
///
/// Uses `GlobalHotkey` rather than the shared event tap, for the reason that file's header
/// records: `RegisterEventHotKey` needs no Accessibility grant, and this feature has no other
/// reason to demand one. Screen Recording is the only permission it declares.
///
/// The UI is reached through closures set by `AppDelegate`, the same separation
/// `ClipboardFeature.showPicker` and `ShelfFeature.showShelf` use, so nothing under `Features/`
/// imports the UI layer.
final class ScreenshotFeature: Feature {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    let id = "screenshot"
    let category = FeatureCategory.capture
    let title = "Screenshots"
    let summary = "Capture an area, a window or the screen"
    let details = """
        Take a screenshot of a selected area, a single window, or the whole screen. The screen \
        freezes while you choose, so menus and tooltips stay put instead of vanishing the moment \
        you click.

        Captures are saved to your capture folder and can be copied, annotated, pinned on top of \
        other windows, or dragged straight into another app.
        """
    let symbolName = "camera.viewfinder"
    var shortcutHint: String? { "⌃⇧A" }

    /// **Screen Recording only.** Not Accessibility: nothing here reads keys or clicks, and
    /// `FeatureCategoryTests` asserts that only `EventTapFeature`s declare it.
    let requirements: Set<Requirement> = [.screenRecording]

    let capturer: ScreenCapturing

    /// Set by `AppDelegate`. Nil until then, and every call site tolerates that — a nil closure is
    /// how a not-yet-built half of the feature is absent rather than crashing.
    var captureFullscreen: (() -> Void)?

    private var hotkeys: [GlobalHotkey] = []

    init(capturer: ScreenCapturing = SCKScreenCaptureService()) {
        self.capturer = capturer
    }

    func activate() {
        let fullscreen = GlobalHotkey(id: GlobalHotkey.ID.captureFullscreen)
        let status = fullscreen.register(keyCode: UInt32(kVK_ANSI_F),
                                         modifiers: UInt32(controlKey | shiftKey)) { [weak self] in
            MainActor.assumeIsolated { self?.captureFullscreen?() }
        }
        if status != noErr {
            // Not fatal, and worth a log rather than a crash: another app holding the combination
            // is a normal thing that happens, and the settings pane reports it properly.
            log.error("couldn't register the fullscreen capture hotkey: \(status, privacy: .public)")
        }
        hotkeys = [fullscreen]
    }

    func deactivate() {
        hotkeys.forEach { $0.unregister() }
        hotkeys = []
    }
}
