import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SwiftUI

/// Expands typed abbreviations into full text.
///
/// **This is the only feature in the app that observes every character the user types**, and the
/// design has to earn that rather than assume it. Nothing here logs, at any level — every other
/// feature logs freely; this one does not get to. The characters live only in
/// `SnippetMatcher.buffer`, which is bounded to the longest trigger plus two and cleared on every
/// interruption below.
final class SnippetFeature: EventTapFeature, ObservableObject {
    let id = "text-snippets"
    let category = FeatureCategory.keyboard
    let title = "Text Snippets"
    let summary = "Type a short trigger, get the full text"
    let details = """
        Type a short trigger and Sarvkrit replaces it with whatever you set. `;addr` becomes your \
        address, `;sig` your sign-off. Each snippet either expands the moment you finish typing the \
        trigger, or waits for a space — so a trigger that's an ordinary word doesn't fire inside a \
        longer one.

        Expansions can carry the date and time: `{date:yyyy-MM-dd}` or `{time}`, the same tokens \
        File Rules uses for renaming.

        This feature has to watch what you type in order to notice a trigger, so it is built to \
        hold as little as possible: only the last few characters, never more than the longest \
        trigger you've defined, never written to disk, and thrown away the moment you switch apps, \
        click, press Return, or use a keyboard shortcut. It also stands down completely while you \
        are typing in a password field.
        """
    let symbolName = "text.badge.plus"
    var shortcutHint: String? { ";today" }

    /// Precomputed: `eventMask` is read once per tap rebuild, but making it a constant keeps it off
    /// the per-event path entirely.
    private static let mask = Sarvkrit.eventMask(.keyDown, .keyUp, .flagsChanged, .leftMouseDown)
    var eventMask: CGEventMask { Self.mask }

    let store: SnippetStore
    private var matcher = SnippetMatcher()

    /// Bundle IDs where snippets never fire.
    var excludedBundleIDs: Set<String> {
        get {
            let stored = defaults.stringArray(forKey: Self.excludedKey)
            return Set(stored ?? Self.defaultExclusions)
        }
        set {
            guard newValue != excludedBundleIDs else { return }
            objectWillChange.send()
            defaults.set(Array(newValue).sorted(), forKey: Self.excludedKey)
        }
    }

    /// Terminals and password managers, excluded out of the box.
    ///
    /// Terminals because a trigger expanding inside a shell command is at best surprising and at
    /// worst destructive; password managers because their fields are exactly where an expansion must
    /// never interfere.
    static let defaultExclusions = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "in.sinew.Enpass-Desktop",
    ]

    private let defaults: UserDefaults
    private static let excludedKey = "snippets.excludedBundleIDs"

    /// Which app is frontmost. Injected so the exclusion rule is testable — a test host can't
    /// control which app the user actually has forward, and "does this stand down where it must"
    /// is not a guarantee to leave unverified.
    private let frontmostBundleID: () -> String?

    /// How an expansion is actually typed. Injected so tests can observe what *would* be typed
    /// rather than typing it into the user's foreground app — which is what they did before.
    private let typeReplacement: (Int, String) -> Void

    /// How long a pause before the buffer is thrown away.
    ///
    /// Not a performance tuning knob — it is a privacy bound. Someone who types a few characters,
    /// walks away and comes back should not have those characters still held.
    private static let idleTimeout: TimeInterval = 8
    private var idleTimer: Timer?

    init(
        store: SnippetStore = SnippetStore(),
        defaults: UserDefaults = .standard,
        frontmostBundleID: @escaping () -> String? = { FrontmostAppMonitor.shared.bundleID },
        typeReplacement: @escaping (Int, String) -> Void = SnippetTyper.replace
    ) {
        self.store = store
        self.defaults = defaults
        self.frontmostBundleID = frontmostBundleID
        self.typeReplacement = typeReplacement
        matcher.setSnippets(store.snippets)
        // Same handshake RuleStore uses: a callback rather than a sink on `$snippets`, because
        // `@Published` emits during `willSet` and the matcher would be rebuilt from the table as it
        // was *before* the edit.
        store.onSnippetsChanged = { [weak self] in
            guard let self else { return }
            self.matcher.setSnippets(self.store.snippets)
        }
    }

    // MARK: - Lifecycle

    func activate() {
        FrontmostAppMonitor.shared.start()
        matcher.setSnippets(store.snippets)
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.matcher.interrupt(.appChanged)
        }
    }

    func deactivate() {
        FrontmostAppMonitor.shared.stop()
        matcher.interrupt(.secureInput)
        swallowedKeyDowns.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
    }

    private var appSwitchObserver: NSObjectProtocol?

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(SnippetDetailView(feature: self, store: store))
    }

    // MARK: - The tap

    /// Keys whose keyDown we consumed, so the matching keyUp goes too. A keyUp arriving for a
    /// keyDown the app never saw leaves its modifier state confused.
    private var swallowedKeyDowns: Set<Int64> = []

    func handle(event: CGEvent, type: CGEventType) -> EventDecision {
        switch type {
        case .leftMouseDown:
            // The caret moved somewhere we can't predict.
            matcher.interrupt(.caretMoved)
            return .pass

        case .flagsChanged:
            return .pass

        case .keyUp:
            return swallowedKeyDowns.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
                ? .swallow : .pass

        case .keyDown:
            break

        default:
            return .pass
        }

        // Stand down entirely while a password field has focus. macOS already stops delivering keys
        // to taps under secure input; clearing as well means we can't resume mid-password holding
        // stale characters.
        if IsSecureEventInputEnabled() {
            matcher.interrupt(.secureInput)
            return .pass
        }

        if let bundleID = frontmostBundleID(), excludedBundleIDs.contains(bundleID) {
            matcher.interrupt(.appChanged)
            return .pass
        }

        let flags = event.flags
        // A shortcut is not typing. Shift and caps lock are, so they don't count.
        if !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) {
            matcher.interrupt(.modifierChord)
            return .pass
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if Self.caretMovingKeys.contains(keyCode) {
            matcher.interrupt(.caretMoved)
            return .pass
        }

        restartIdleTimer()

        switch matcher.typed(character(from: event)) {
        case .ignore:
            return .pass

        case .expand(_, let deleteCount, let expansion):
            swallowedKeyDowns.insert(keyCode)
            // Off the tap callback: posting events from inside it re-enters the tap machinery.
            DispatchQueue.main.async {
                self.typeReplacement(deleteCount, expansion)
            }
            return .swallow
        }
    }

    /// Return, Tab, Escape and the arrows all move the caret somewhere the buffer can't follow.
    private static let caretMovingKeys: Set<Int64> = [
        36,   // Return
        76,   // Numpad Enter
        48,   // Tab
        53,   // Escape
        51,   // Delete — the text behind the caret changed
        117,  // Forward delete
        123, 124, 125, 126,   // Arrows
        115, 119, 116, 121,   // Home, End, Page Up, Page Down
    ]

    /// What the keystroke actually produced, rather than what key was pressed.
    ///
    /// Reading the unicode string rather than mapping the keycode is what makes this work on
    /// non-US layouts: on a French keyboard the key at position 0 types `q`, and a keycode table
    /// would have the trigger wrong on every non-QWERTY Mac.
    private func character(from event: CGEvent) -> Character? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        let string = String(utf16CodeUnits: buffer, count: length)
        // One grapheme, or nothing: a dead key producing a combining mark alone isn't a character
        // the user has finished typing.
        guard string.count == 1, let character = string.first, !character.isNewline else { return nil }
        return character
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) {
            [weak self] _ in
            self?.matcher.interrupt(.idle)
        }
    }
}
