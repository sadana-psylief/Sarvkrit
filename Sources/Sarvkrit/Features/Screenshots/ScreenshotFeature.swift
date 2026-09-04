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
    let shortcuts: ScreenshotShortcutStore

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

    /// The last area that was actually captured, for retaking it.
    ///
    /// Global AppKit points. Stored as four numbers rather than an archived rect so a future
    /// change to how rects are persisted cannot make an old value decode as something plausible
    /// but wrong — the failure mode there is a capture of the wrong part of the screen.
    var lastSelection: CGRect? {
        get {
            guard let values = defaults.array(forKey: "screenshot.lastSelection") as? [Double],
                  values.count == 4, values[2] > 0, values[3] > 0
            else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        set {
            guard let newValue, newValue.width > 0, newValue.height > 0 else {
                defaults.removeObject(forKey: "screenshot.lastSelection")
                return
            }
            defaults.set([newValue.minX, newValue.minY, newValue.width, newValue.height],
                         forKey: "screenshot.lastSelection")
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
                .flatMap(QuickAccessPlacement.Corner.init(rawValue:)) ?? .bottomLeft
        }
        set {
            guard newValue != quickAccessCorner else { return }
            defaults.set(newValue.rawValue, forKey: "screenshot.quickAccessCorner")
            objectWillChange.send()
        }
    }

    /// Zero means "stay until dismissed", which is how a nil is expressible in UserDefaults
    /// without a second key.
    ///
    /// **Zero is the default.** The promise this overlay makes is that a capture is still there
    /// when you turn back to it — reach for it a few seconds later and find it gone and you stop
    /// trusting it, which is worse than having no overlay at all. It goes when you act on it, when
    /// the next capture arrives, or when you dismiss it.
    var quickAccessAutoCloseSeconds: Double {
        get { defaults.object(forKey: "screenshot.quickAccessSeconds") as? Double ?? 0 }
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

    /// Where the readable copies go. Nil means the history folder only.
    ///
    /// Stored as a path rather than a bookmark because the app is not sandboxed — a bookmark
    /// would buy nothing here, and `Rule` only uses one because a *watched* folder has to survive
    /// being renamed while the app is running.
    var exportFolderPath: String? {
        get { defaults.string(forKey: "screenshot.exportFolder") }
        set {
            guard newValue != exportFolderPath else { return }
            defaults.set(newValue, forKey: "screenshot.exportFolder")
            applyExportSettings()
            objectWillChange.send()
        }
    }

    var exportFolder: URL? { exportFolderPath.map { URL(fileURLWithPath: $0) } }

    var filenamePattern: String {
        get { defaults.string(forKey: "screenshot.filenamePattern") ?? CaptureFilename.defaultPattern }
        set {
            guard newValue != filenamePattern else { return }
            defaults.set(newValue, forKey: "screenshot.filenamePattern")
            applyExportSettings()
            objectWillChange.send()
        }
    }

    private func applyExportSettings() {
        store.exportFolder = exportFolder
        store.exportPattern = filenamePattern
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
    var captureScrolling: (() -> Void)?
    var recognizeText: (() -> Void)?
    var showHistory: (() -> Void)?

    private var hotkeys: [GlobalHotkey] = []

    init(capturer: ScreenCapturing = SCKScreenCaptureService(),
         store: CaptureHistoryStore? = nil,
         defaults: UserDefaults = .standard) {
        self.capturer = capturer
        self.defaults = defaults
        self.shortcuts = ScreenshotShortcutStore(defaults: defaults)
        let retention = (defaults.string(forKey: "screenshot.retention")
            .flatMap(CaptureRetention.Window.init(rawValue:))) ?? .month
        self.store = store ?? CaptureHistoryStore(retention: retention)
        applyExportSettings()
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(ScreenshotDetailView(feature: self, store: store))
    }

    func activate() {
        rebindHotkeys()
    }

    /// Registers every capture shortcut from the store.
    ///
    /// Called again after a rebind, because Carbon hotkeys are registered rather than matched —
    /// there is no lookup table to update, only a registration to replace.
    func rebindHotkeys() {
        hotkeys.forEach { $0.unregister() }
        hotkeys = []
        failedRegistrations = []

        for action in ScreenshotAction.allCases {
            guard let handler = handler(for: action),
                  let shortcut = shortcuts.shortcut(for: action) else { continue }
            let hotkey = GlobalHotkey(id: action.hotkeyID)
            let status = hotkey.register(
                keyCode: UInt32(shortcut.keyCode),
                // Carbon masks, not CGEventFlags. Handing over the wrong one compiles and
                // registers a different combination — see `CarbonModifiers`.
                modifiers: CarbonModifiers.from(shortcut.flags)
            ) { MainActor.assumeIsolated { handler() } }

            if status == noErr {
                hotkeys.append(hotkey)
                // The successes are logged too, not only the refusals: "did this combination
                // actually get claimed on this Mac" is otherwise unanswerable without a debugger.
                log.info("registered \(action.rawValue, privacy: .public) keyCode \(shortcut.keyCode, privacy: .public)")
            } else {
                // Not fatal: another app holding a combination is ordinary. Recorded so the
                // settings pane can say so, rather than offering a shortcut that does nothing.
                failedRegistrations.insert(action)
                log.error("couldn't register \(action.rawValue, privacy: .public): \(status, privacy: .public)")
            }
        }
        objectWillChange.send()
    }

    /// Actions whose registration was refused, so settings can report it honestly.
    private(set) var failedRegistrations: Set<ScreenshotAction> = []

    /// Runs an action, whatever asked for it.
    ///
    /// The hotkeys and the `sarvkrit://` URL scheme both come through here, so a mode cannot end
    /// up reachable by one and not the other — which is exactly what happens when a URL handler
    /// grows its own copy of the switch.
    func perform(_ action: ScreenshotAction) {
        log.info("perform \(action.rawValue, privacy: .public)")
        handler(for: action)?()
    }

    private func handler(for action: ScreenshotAction) -> (() -> Void)? {
        switch action {
        case .area: return { [weak self] in self?.captureArea?() }
        case .window: return { [weak self] in self?.captureWindow?() }
        case .fullscreen: return { [weak self] in self?.captureFullscreen?() }
        case .allInOne: return { [weak self] in self?.showAllInOne?() }
        case .restoreOverlay: return { [weak self] in self?.restoreLastOverlay?() }
        case .hideOverlays: return { [weak self] in self?.hideOverlays?() }
        case .scrolling: return { [weak self] in self?.captureScrolling?() }
        case .textRecognition: return { [weak self] in self?.recognizeText?() }
        case .history: return { [weak self] in self?.showHistory?() }
        // Owned by PinToScreenFeature, which registers it itself.
        case .pinClipboard: return nil
        }
    }

    func deactivate() {
        hotkeys.forEach { $0.unregister() }
        hotkeys = []
    }
}
