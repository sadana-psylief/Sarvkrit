import AppKit
import CoreGraphics
import Foundation

/// Deletes the typed trigger and types the expansion in its place.
///
/// **Deliberately does not use the pasteboard.** Putting the expansion on the pasteboard and sending
/// ⌘V is the obvious implementation and it is wrong here for a reason specific to this app: it would
/// land every expansion in the user's own Clipboard History, and clobber whatever they had copied.
///
/// There is a nice confirmation that this is the known trap — `ClipboardPrivacyFilter.excludedTypes`
/// already carries `de.petermaurer.TransientPasteboardType` and `com.typeit4me.clipping`, markers
/// that *other snippet expanders* set precisely so clipboard managers ignore their traffic. Not
/// touching the pasteboard sidesteps the problem rather than negotiating with it.
enum SnippetTyper {

    /// Virtual keycodes for the two keys we press rather than type.
    private static let deleteKey: CGKeyCode = 51
    private static let returnKey: CGKeyCode = 36

    /// - Parameters:
    ///   - deleteCount: how many characters the user typed that must come back out.
    ///   - text: the already-expanded replacement.
    static func replace(deleteCount: Int, with text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        for _ in 0..<max(0, deleteCount) {
            press(deleteKey, source: source)
        }

        // Newlines are pressed rather than typed. `keyboardSetUnicodeString` with a "\n" in it is
        // honoured inconsistently — some apps insert nothing at all — whereas a Return keypress is
        // unambiguous everywhere.
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { press(returnKey, source: source) }
            guard !line.isEmpty else { continue }
            type(line, source: source)
        }
    }

    /// Types a string as one event pair.
    ///
    /// `keyboardSetUnicodeString` is what makes this layout-independent: there is no keycode to map,
    /// so it works on Dvorak and for emoji alike. Posting with `virtualKey: 0` and overriding the
    /// string is the documented way to emit text that has no key of its own.
    private static func type(_ text: String, source: CGEventSource) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        let utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        post(down, up)
    }

    private static func press(_ keyCode: CGKeyCode, source: CGEventSource) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        post(down, up)
    }

    private static func post(_ down: CGEvent, _ up: CGEvent) {
        // Without the tag these re-enter our own tap and the matcher sees its own expansion as
        // typing — which for a snippet whose expansion contains its trigger would loop. The tap
        // skips tagged events centrally, before any feature sees them.
        EventTapService.tagAsSynthetic(down)
        EventTapService.tagAsSynthetic(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
