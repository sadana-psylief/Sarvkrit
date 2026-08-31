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
        return nil
    }
}
