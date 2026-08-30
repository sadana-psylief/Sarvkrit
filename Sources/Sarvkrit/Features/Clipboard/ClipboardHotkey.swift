import CoreGraphics
import Foundation

/// The clipboard's global shortcuts, matched purely from a key event.
///
/// Split out so the exact modifier discipline is a table of test cases. Being too permissive here
/// means swallowing keystrokes that belong to whatever app the user is actually typing in.
enum ClipboardHotkey: Equatable {
    /// ⌘⇧C — open the picker at the cursor.
    case open
    /// ⌃⌥1…5 — paste that entry straight away, no UI.
    case pasteIndex(Int)

    // ANSI virtual key codes. Note 5 is 23, not 22 — 22 is 6.
    static let keyC: Int64 = 8
    static let digitKeyCodes: [Int64] = [18, 19, 20, 21, 23]   // 1, 2, 3, 4, 5

    static func match(keyCode: Int64, flags: CGEventFlags) -> ClipboardHotkey? {
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

        // ⌘⇧C to open. Command and shift, and nothing else — ⌘⌥⇧C belongs to somebody else.
        if keyCode == keyC, modifiers == [.maskCommand, .maskShift] { return .open }

        // ⌃⌥ + digit for global direct paste.
        //
        // NOT ⌘-digit: ⌘1–9 switches tabs in Safari, Chrome, Slack and nearly every tabbed app, and
        // swallowing it system-wide would break normal use within minutes. ⌃1–4 is macOS Spaces and
        // ⌥-digit types ¡™£¢∞, so those are out too. ⌃⌥ + digit is about the only digit combination
        // nothing claims. ⌘1–5 still works — but only inside the picker, where nothing else is
        // listening.
        if modifiers == [.maskControl, .maskAlternate],
           let position = digitKeyCodes.firstIndex(of: keyCode) {
            return .pasteIndex(position + 1)
        }
        return nil
    }

    /// ⌘1–5 while the picker has focus. Separate from `match` on purpose: this is only ever
    /// consulted when the picker is up, so it can safely claim a shortcut that is unusable globally.
    static func pickerIndex(keyCode: Int64, flags: CGEventFlags) -> Int? {
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard modifiers == .maskCommand,
              let position = digitKeyCodes.firstIndex(of: keyCode) else { return nil }
        return position + 1
    }
}
