import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI
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
final class ScreenshotFeature: Feature, ObservableObject {
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
    let store: CaptureHistoryStore

    private let defaults: UserDefaults

    /// Settings are hand-rolled computed properties over an injected `UserDefaults` with a
    /// same-value guard in the setter — the idiom every other feature here uses, and for the
    /// reason `AppState` documents: a same-value write through a SwiftUI two-way binding once
    /// created an infinite notify/invalidate loop that pinned a CPU core.
    var savesToDisk: Bool {
        get { defaults.object(forKey: "screenshot.savesToDisk") as? Bool ?? true }
        set {
            guard newValue != savesToDisk else { return }
            defaults.set(newValue, forKey: "screenshot.savesToDisk")
            objectWillChange.send()
        }
    }

    var copiesToClipboard: Bool {
        get { defaults.object(forKey: "screenshot.copiesToClipboard") as? Bool ?? false }
        set {
            guard newValue != copiesToClipboard else { return }
            defaults.set(newValue, forKey: "screenshot.copiesToClipboard")
            objectWillChange.send()
        }
    }

    var hidesDesktopIcons: Bool {
        get { defaults.object(forKey: "screenshot.hidesDesktopIcons") as? Bool ?? false }
        set {
            guard newValue != hidesDesktopIcons else { return }
            defaults.set(newValue, forKey: "screenshot.hidesDesktopIcons")
            objectWillChange.send()
        }
    }

    var showsCursor: Bool {
        get { defaults.object(forKey: "screenshot.showsCursor") as? Bool ?? false }
        set {
            guard newValue != showsCursor else { return }
            defaults.set(newValue, forKey: "screenshot.showsCursor")
            objectWillChange.send()
        }
    }

    var showsCrosshair: Bool {
        get { defaults.object(forKey: "screenshot.showsCrosshair") as? Bool ?? true }
        set {
            guard newValue != showsCrosshair else { return }
            defaults.set(newValue, forKey: "screenshot.showsCrosshair")
            objectWillChange.send()
        }
    }

    var showsMagnifier: Bool {
        get { defaults.object(forKey: "screenshot.showsMagnifier") as? Bool ?? true }
        set {
            guard newValue != showsMagnifier else { return }
            defaults.set(newValue, forKey: "screenshot.showsMagnifier")
            objectWillChange.send()
        }
    }

    var showsDimensions: Bool {
        get { defaults.object(forKey: "screenshot.showsDimensions") as? Bool ?? true }
        set {
            guard newValue != showsDimensions else { return }
            defaults.set(newValue, forKey: "screenshot.showsDimensions")
            objectWillChange.send()
        }
    }

    var overlayChrome: CaptureOverlayController.Chrome {
        .init(showsCrosshair: showsCrosshair,
              showsMagnifier: showsMagnifier,
              showsDimensions: showsDimensions)
    }

    var includesWindowShadow: Bool {
        get { defaults.object(forKey: "screenshot.includesWindowShadow") as? Bool ?? true }
        set {
            guard newValue != includesWindowShadow else { return }
            defaults.set(newValue, forKey: "screenshot.includesWindowShadow")
            objectWillChange.send()
        }
    }

    var transparentWindowBackground: Bool {
        get { defaults.object(forKey: "screenshot.transparentWindowBackground") as? Bool ?? false }
        set {
            guard newValue != transparentWindowBackground else { return }
            defaults.set(newValue, forKey: "screenshot.transparentWindowBackground")
            objectWillChange.send()
        }
    }

    var captureOptions: CaptureOptions {
        var options = CaptureOptions()
        options.hidesDesktopIcons = hidesDesktopIcons
        options.includesShadow = includesWindowShadow
        options.transparentBackground = transparentWindowBackground
        // Never for the frozen snapshot itself — the overlay draws its own crosshair, and a frozen
        // cursor sitting under the live one reads as a rendering fault. This is applied when the
        // final image is taken, not when the screen is frozen.
        options.showsCursor = false
        return options
    }

    var showsQuickAccess: Bool {
        get { defaults.object(forKey: "screenshot.showsQuickAccess") as? Bool ?? true }
        set {
            guard newValue != showsQuickAccess else { return }
            defaults.set(newValue, forKey: "screenshot.showsQuickAccess")
            objectWillChange.send()
        }
    }

    var quickAccessCorner: QuickAccessPlacement.Corner {
        get {
            defaults.string(forKey: "screenshot.quickAccessCorner")
                .flatMap(QuickAccessPlacement.Corner.init(rawValue:)) ?? .bottomRight
        }
        set {
            guard newValue != quickAccessCorner else { return }
            defaults.set(newValue.rawValue, forKey: "screenshot.quickAccessCorner")
            objectWillChange.send()
        }
    }

    /// Zero means "stay until dismissed", which is how a nil is expressible in UserDefaults
    /// without a second key.
    var quickAccessAutoCloseSeconds: Double {
        get { defaults.object(forKey: "screenshot.quickAccessSeconds") as? Double ?? 8 }
        set {
            guard newValue != quickAccessAutoCloseSeconds else { return }
            defaults.set(newValue, forKey: "screenshot.quickAccessSeconds")
            objectWillChange.send()
        }
    }

    var quickAccessAutoClose: TimeInterval? {
        quickAccessAutoCloseSeconds > 0 ? quickAccessAutoCloseSeconds : nil
    }

    /// The picker's last selection, so a retake is one keypress.
    var modeMemory: CaptureModeMemory {
        get { CaptureModeMemory.load(from: defaults) }
        set {
            guard newValue != modeMemory else { return }
            newValue.save(to: defaults)
            objectWillChange.send()
        }
    }

    var selfTimerSeconds: Int {
        get { defaults.object(forKey: "screenshot.selfTimerSeconds") as? Int ?? 0 }
        set {
            guard newValue != selfTimerSeconds else { return }
            defaults.set(newValue, forKey: "screenshot.selfTimerSeconds")
            objectWillChange.send()
        }
    }

    var destinationSettings: CaptureDestination.Settings {
        CaptureDestination.Settings(savesToDisk: savesToDisk,
                                    copiesToClipboard: copiesToClipboard,
                                    showsQuickAccess: showsQuickAccess,
                                    opensEditor: false)
    }

    /// Set by `AppDelegate`. Nil until then, and every call site tolerates that — a nil closure is
    /// how a not-yet-built half of the feature is absent rather than crashing.
    var captureFullscreen: (() -> Void)?
    var captureArea: (() -> Void)?
    var captureWindow: (() -> Void)?
    var restoreLastOverlay: (() -> Void)?
    var hideOverlays: (() -> Void)?
    var showAllInOne: (() -> Void)?

    private var hotkeys: [GlobalHotkey] = []

    init(capturer: ScreenCapturing = SCKScreenCaptureService(),
         store: CaptureHistoryStore? = nil,
         defaults: UserDefaults = .standard) {
        self.capturer = capturer
        self.defaults = defaults
        let retention = (defaults.string(forKey: "screenshot.retention")
            .flatMap(CaptureRetention.Window.init(rawValue:))) ?? .month
        self.store = store ?? CaptureHistoryStore(retention: retention)
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(ScreenshotDetailView(feature: self, store: store))
    }

    func activate() {
        hotkeys = [
            bind(id: GlobalHotkey.ID.captureArea, key: kVK_ANSI_A, name: "area") { [weak self] in
                self?.captureArea?()
            },
            bind(id: GlobalHotkey.ID.captureWindow, key: kVK_ANSI_W, name: "window") { [weak self] in
                self?.captureWindow?()
            },
            bind(id: GlobalHotkey.ID.captureAllInOne, key: kVK_ANSI_5, name: "all-in-one") { [weak self] in
                self?.showAllInOne?()
            },
            bind(id: GlobalHotkey.ID.restoreLastOverlay, key: kVK_ANSI_Z, name: "restore overlay") { [weak self] in
                self?.restoreLastOverlay?()
            },
            bind(id: GlobalHotkey.ID.hideOverlays, key: kVK_ANSI_H, name: "hide overlays") { [weak self] in
                self?.hideOverlays?()
            },
            bind(id: GlobalHotkey.ID.captureFullscreen, key: kVK_ANSI_F, name: "fullscreen") { [weak self] in
                self?.captureFullscreen?()
            },
        ]
    }

    /// ⌃⇧ plus a letter.
    ///
    /// **Not ⌘⇧3/4/5.** Those belong to the system screenshot service, which claims them below
    /// `RegisterEventHotKey` — registering one either reports `eventHotKeyExistsErr` or succeeds
    /// and never fires, and a shortcut that silently does nothing is the worst of the options.
    /// ⌃⌥ is already crowded: window management owns most of the letters, the Shelf has S, and
    /// the clipboard has ⌃⌥1–5. ⌃⇧ is free.
    private func bind(id: UInt32, key: Int, name: String,
                      onFire: @escaping () -> Void) -> GlobalHotkey {
        let hotkey = GlobalHotkey(id: id)
        let status = hotkey.register(keyCode: UInt32(key),
                                     modifiers: UInt32(controlKey | shiftKey)) {
            MainActor.assumeIsolated { onFire() }
        }
        if status != noErr {
            // Another app holding the combination is a normal thing that happens, and the settings
            // pane reports it properly. Worth a log, not a crash.
            log.error("couldn't register the \(name, privacy: .public) capture hotkey: \(status, privacy: .public)")
        }
        return hotkey
    }

    func deactivate() {
        hotkeys.forEach { $0.unregister() }
        hotkeys = []
    }
}
