import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import os

/// Clipboard history: capture, hotkeys, and paste.
///
/// The first feature to use the shared tap's `.swallow` decision — ⌘⇧C has to be taken from the app
/// underneath, or the picker opens *and* the app sees the shortcut.
final class ClipboardFeature: EventTapFeature, ObservableObject {
    let id = "clipboard-history"
    let category = FeatureCategory.clipboard
    let title = "Clipboard History"
    let summary = "Keep and re-paste what you copy"
    let details = """
        Keeps what you copy so you can paste it again later. Press ⌘⇧C to open the list at your \
        cursor, type to search, and press Return to paste — or ⌘1 through ⌘5 to pick one directly.

        ⌃⌥1 through ⌃⌥5 paste the first five entries without opening anything. That combination \
        looks awkward because it has to be: ⌘1–5 belongs to your browser's tabs, and taking it \
        system-wide would break far more than it fixed.

        Copies that a password manager marks as confidential are never recorded — not stored and \
        then hidden, but never read at all. Apps you add to the ignore list are skipped the same \
        way, which is worth doing for password managers that don't set that marker correctly.
        """
    let symbolName = "doc.on.clipboard"
    let shortcutHint: String? = "⌘⇧C"

    /// No Accessibility for the *history* — but the hotkeys and the synthetic ⌘V both need the
    /// event tap, so the feature as a whole does.
    let requirements: Set<Requirement> = [.accessibility]

    var eventMask: CGEventMask { Sarvkrit.eventMask(.keyDown, .keyUp) }

    let store: ClipboardStore
    @Published private(set) var settings: ClipboardSettings

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Clipboard")
    private let defaults: UserDefaults
    private var monitor: ClipboardMonitor?
    private lazy var paster = Paster(store: store)
    /// Key codes whose keyDown we swallowed, so the matching keyUp goes too. Letting the up
    /// through on its own leaves the receiving app with confused modifier state.
    private var swallowedKeyDowns: Set<Int64> = []

    /// Whoever was frontmost when the picker opened — the app a paste must return to.
    private(set) var pasteTarget: NSRunningApplication?

    /// Set by the feature so the UI layer can present the picker without this type importing it.
    var showPicker: (() -> Void)?

    private static let settingsKey = "clipboard.settings"

    init(store: ClipboardStore = ClipboardStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.settings = Self.loadSettings(from: defaults)
    }

    // MARK: - Lifecycle

    func activate() {
        let monitor = ClipboardMonitor { [weak self] snapshot in self?.handleCopy(snapshot) }
        monitor.start()
        self.monitor = monitor
    }

    func deactivate() {
        monitor?.stop()
        monitor = nil
        swallowedKeyDowns.removeAll()
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(ClipboardDetailView(feature: self, store: store))
    }

    // MARK: - Settings

    func update(_ transform: (inout ClipboardSettings) -> Void) {
        var copy = settings
        transform(&copy)
        guard copy != settings else { return }
        objectWillChange.send()
        settings = copy
        saveSettings()
    }

    private func saveSettings() {
        let encoded: [String: Any] = [
            "storeText": settings.storeText,
            "storeImages": settings.storeImages,
            "storeFiles": settings.storeFiles,
            "maxItemSizeMB": settings.maxItemSizeMB,
            "historyLimit": settings.historyLimit,
            "pasteImmediately": settings.pasteImmediately,
            "ignoredBundleIDs": Array(settings.ignoredBundleIDs).sorted(),
            "sortMode": settings.sortMode.rawValue,
            "searchMode": settings.searchMode.rawValue,
            "pinnedPosition": settings.pinnedPosition.rawValue,
            "imageRowHeight": settings.imageRowHeight,
            "previewDelayMilliseconds": settings.previewDelayMilliseconds,
            "showAppIcons": settings.showAppIcons,
            "highlightMatches": settings.highlightMatches,
        ]
        defaults.set(encoded, forKey: Self.settingsKey)
    }

    private static func loadSettings(from defaults: UserDefaults) -> ClipboardSettings {
        guard let raw = defaults.dictionary(forKey: settingsKey) else { return ClipboardSettings() }
        var settings = ClipboardSettings()
        settings.storeText = raw["storeText"] as? Bool ?? true
        settings.storeImages = raw["storeImages"] as? Bool ?? true
        settings.storeFiles = raw["storeFiles"] as? Bool ?? true
        settings.maxItemSizeMB = raw["maxItemSizeMB"] as? Int ?? 0
        settings.historyLimit = raw["historyLimit"] as? Int ?? 200
        settings.pasteImmediately = raw["pasteImmediately"] as? Bool ?? true
        settings.ignoredBundleIDs = Set(raw["ignoredBundleIDs"] as? [String] ?? [])
        // Each falls back to its default, so a settings file written before these existed loads
        // cleanly rather than resetting everything.
        settings.sortMode = (raw["sortMode"] as? String).flatMap(ClipboardSortMode.init) ?? .lastCopy
        settings.searchMode = (raw["searchMode"] as? String).flatMap(ClipboardSearch.Mode.init) ?? .exact
        settings.pinnedPosition = (raw["pinnedPosition"] as? String).flatMap(PinnedPosition.init) ?? .top
        settings.imageRowHeight = raw["imageRowHeight"] as? Int ?? 40
        settings.previewDelayMilliseconds = raw["previewDelayMilliseconds"] as? Int ?? 1_500
        settings.showAppIcons = raw["showAppIcons"] as? Bool ?? true
        settings.highlightMatches = raw["highlightMatches"] as? Bool ?? true
        return settings
    }

    // MARK: - Capture

    private func handleCopy(_ probe: ClipboardCapturePolicy.Snapshot) {
        // The gate, before any content is read.
        guard ClipboardPrivacyFilter.shouldRecord(
            types: probe.types,
            sourceBundleID: probe.declaredSource,
            ignoredBundleIDs: settings.ignoredBundleIDs
        ) else { return }

        guard let monitor else { return }
        let snapshot = monitor.readContent(types: probe.types, source: probe.declaredSource)

        switch ClipboardCapturePolicy.outcome(for: snapshot, settings: settings) {
        case .skip:
            return

        case .files(let paths):
            record(.files(paths), source: probe.declaredSource)

        case .image(let bytes, let width, let height):
            guard let data = monitor.pngPayload(),
                  let name = store.writePayload(data, extension: "png") else { return }
            record(.image(fileName: name, width: width, height: height, byteCount: bytes),
                   source: probe.declaredSource)

        case .richText(let plain):
            guard let rtf = monitor.rtfPayload(),
                  let name = store.writePayload(rtf, extension: "rtf") else {
                record(.text(plain), source: probe.declaredSource)
                return
            }
            record(.richText(fileName: name, plain: plain), source: probe.declaredSource)

        case .text(let value):
            guard ClipboardCapturePolicy.shouldSpillToFile(value) else {
                record(.text(value), source: probe.declaredSource)
                return
            }
            guard let name = store.writePayload(Data(value.utf8), extension: "txt") else { return }
            record(
                .largeText(fileName: name, preview: String(value.prefix(200)), characterCount: value.count),
                source: probe.declaredSource)
        }
    }

    private func record(_ kind: ClipboardItem.Kind, source: String?) {
        let item = ClipboardItem(kind: kind, sourceBundleID: source)
        DispatchQueue.main.async {
            self.store.add(item, limit: self.settings.historyLimit)
        }
    }

    // MARK: - Hotkeys

    func handle(event: CGEvent, type: CGEventType) -> EventDecision {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            // Paired with the swallowed keyDown; releasing it alone confuses the receiving app.
            return swallowedKeyDowns.remove(keyCode) != nil ? .swallow : .pass
        }
        guard type == .keyDown else { return .pass }
        guard let hotkey = ClipboardHotkey.match(keyCode: keyCode, flags: event.flags) else {
            return .pass
        }

        swallowedKeyDowns.insert(keyCode)
        // Off the tap callback: showing a panel or pasting must not run inside the event tap.
        DispatchQueue.main.async { self.perform(hotkey) }
        return .swallow
    }

    private func perform(_ hotkey: ClipboardHotkey) {
        // Captured before anything steals focus, so a paste knows where to go back to.
        pasteTarget = NSWorkspace.shared.frontmostApplication

        switch hotkey {
        case .open:
            showPicker?()
        case .pasteIndex(let index):
            let entries = store.ordered(sortedBy: settings.sortMode, pinned: settings.pinnedPosition)
            guard entries.indices.contains(index - 1) else { return }
            paste(entries[index - 1], asPlainText: false)
        }
    }

    // MARK: - Pasting

    func paste(_ item: ClipboardItem, asPlainText: Bool) {
        // Putting the item on the pasteboard is itself a pasteboard change; without this the
        // monitor would record the paste as a brand-new copy.
        monitor?.suppressNextChange()

        guard paster.place(item, asPlainText: asPlainText) else {
            log.warning("clipboard entry could not be pasted — its file has probably moved")
            return
        }
        guard settings.pasteImmediately else { return }
        paster.pasteIntoFrontmost(restoring: pasteTarget)
    }
}
