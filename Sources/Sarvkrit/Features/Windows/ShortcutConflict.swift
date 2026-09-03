import CoreGraphics
import Foundation

/// Whether a key combination may be bound to a window action, and what it would cost.
///
/// The point of this file is that a shortcut recorder which accepts anything is actively harmful:
/// Sarvkrit's tap swallows what it matches, so a careless binding doesn't merely fail to work — it
/// takes the key away from every app on the system. ⌘Q bound here would make quitting impossible.
///
/// Pure, so the whole policy is a test table.
enum ShortcutConflict {

    enum Verdict: Equatable {
        /// Nothing else wants it.
        case available
        /// Allowed, but it takes the combination from another window action, which is left unbound.
        case stealsFromWindowAction(WindowAction)
        /// The same, for any other named owner. A separate case rather than a generalisation of
        /// the one above, because `ShortcutConflictTests` pins that one's exact wording.
        case stealsFrom(String)
        /// Allowed, but another Sarvkrit feature listens for it too, and that feature would break.
        case conflictsWithFeature(String)
        /// Not allowed — the system or the user would lose something they can't get back.
        case refused(String)

        var isAllowed: Bool {
            if case .refused = self { return false }
            return true
        }

        /// One line for the recorder to show under the field.
        var message: String? {
            switch self {
            case .available:
                return nil
            case .stealsFromWindowAction(let action):
                return "Currently used by \(action.title). Recording this will unbind it."
            case .stealsFrom(let name):
                return "Currently used by \(name). Recording this will unbind it."
            case .conflictsWithFeature(let feature):
                return "Also used by \(feature). One of the two will stop working."
            case .refused(let reason):
                return reason
            }
        }
    }

    /// - Parameter existing: the current window bindings, to detect a steal.
    static func verdict(
        for shortcut: WindowShortcut,
        existing: [WindowAction: WindowShortcut],
        assigningTo action: WindowAction
    ) -> Verdict {
        let modifiers = shortcut.flags
        let key = shortcut.keyCode

        // A bare key, or shift plus a key, is what the user types. Binding "A" would snap a window
        // on every A they type anywhere — and, because we swallow, the letter would never arrive.
        if modifiers.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) {
            return .refused("Needs at least one of ⌘, ⌃ or ⌥ — otherwise it fires while you type.")
        }

        if let reason = systemRefusal(keyCode: key, modifiers: modifiers) {
            return .refused(reason)
        }

        if let feature = featureConflict(keyCode: key, modifiers: modifiers) {
            return .conflictsWithFeature(feature)
        }

        if let (other, _) = existing.first(where: { $0.value == shortcut && $0.key != action }) {
            return .stealsFromWindowAction(other)
        }

        return .available
    }

    /// The same policy for any other family of shortcuts.
    ///
    /// **Deliberately a second function rather than a generalisation of the first.**
    /// `ShortcutConflictTests` pins fifteen assertions about the `WindowAction` entry point,
    /// including the exact wording of `stealsFromWindowAction`, and churning a policy file that
    /// well covered to save one function is a poor trade. The shared rules live in the private
    /// helpers below, which both call.
    static func verdict<Owner: ShortcutOwner>(
        for shortcut: WindowShortcut,
        existing: [Owner: WindowShortcut],
        assigningTo owner: Owner
    ) -> Verdict {
        let modifiers = shortcut.flags
        let key = shortcut.keyCode

        if modifiers.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate]) {
            return .refused("Needs at least one of ⌘, ⌃ or ⌥ — otherwise it fires while you type.")
        }
        if let reason = systemRefusal(keyCode: key, modifiers: modifiers) {
            return .refused(reason)
        }
        if let feature = featureConflict(keyCode: key, modifiers: modifiers) {
            return .conflictsWithFeature(feature)
        }
        if let (other, _) = existing.first(where: { $0.value == shortcut && $0.key != owner }) {
            return .stealsFrom(other.shortcutTitle)
        }
        return .available
    }

    /// Combinations macOS reserves, where swallowing would leave the user stuck.
    private static func systemRefusal(keyCode: Int64, modifiers: CGEventFlags) -> String? {
        let command: CGEventFlags = [.maskCommand]
        switch (keyCode, modifiers) {
        case (12, command):     // ⌘Q
            return "⌘Q quits apps. Sarvkrit won't take that over."
        case (13, command):     // ⌘W
            return "⌘W closes windows. Sarvkrit won't take that over."
        case (WindowShortcut.tabKey, command),
             (WindowShortcut.tabKey, [.maskCommand, .maskShift]):
            return "⌘Tab switches apps. Sarvkrit won't take that over."
        case (WindowShortcut.spaceKey, command):
            return "⌘Space opens Spotlight. Sarvkrit won't take that over."
        case (WindowShortcut.escapeKey, _):
            return "⎋ cancels — it can't be a shortcut."
        default:
            return nil
        }
    }

    /// Sarvkrit's own shortcuts. These aren't refused — a user who prefers the window action is
    /// entitled to it — but the cost is spelled out rather than discovered later.
    private static func featureConflict(keyCode: Int64, modifiers: CGEventFlags) -> String? {
        if let hotkey = ClipboardHotkey.match(keyCode: keyCode, flags: modifiers) {
            switch hotkey {
            case .open: return "Clipboard History (open the picker)"
            case .pasteIndex(let index): return "Clipboard History (paste item \(index))"
            }
        }
        if modifiers == [.maskCommand],
           keyCode == CutPasteRewriter.keyX || keyCode == CutPasteRewriter.keyV {
            return "Finder Cut & Paste"
        }
        // ⌘⇧3/4/5/6 belong to the macOS screenshot service, which claims them below
        // `RegisterEventHotKey`. Warned rather than refused, on the same principle as the
        // clipboard conflicts: the user is entitled to prefer ours, but not to find out later
        // that it silently never fires.
        if modifiers == [.maskCommand, .maskShift],
           ScreenshotSystemKeys.keyCodes.contains(keyCode) {
            return "the macOS screenshot shortcuts"
        }
        return nil
    }
}

/// Something a shortcut can be bound to.
///
/// Exists so the recorder and the conflict policy can serve both the window actions and the
/// capture actions without either knowing about the other.
protocol ShortcutOwner: Hashable {
    var shortcutTitle: String { get }
}

extension WindowAction: ShortcutOwner {
    var shortcutTitle: String { title }
}

extension ScreenshotAction: ShortcutOwner {
    var shortcutTitle: String { title }
}

/// The keys macOS's own screenshot service owns.
enum ScreenshotSystemKeys {
    /// ⌘⇧3, 4, 5, 6.
    static let keyCodes: Set<Int64> = [20, 21, 23, 22]
}
