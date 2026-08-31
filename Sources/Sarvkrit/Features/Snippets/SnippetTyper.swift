import AppKit
import CoreGraphics
import Foundation
import os

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
        // A test that reaches this types into whatever app the user is looking at, and *passes*.
        // See `AppIdentity.isRunningTests` for the incident this prevents recurring.
        guard !AppIdentity.isRunningTests else { return }
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

    /// Diagnostics for a stray keystroke that inspection couldn't explain.
    ///
    /// Logs **only events this app synthesizes** — never what the user types. Snippets is built
    /// around holding as little as possible, and a diagnostic that quietly wrote keystrokes to the
    /// system log would undo the whole point of it.
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SnippetTyper")

    private static func post(_ down: CGEvent, _ up: CGEvent) {
        // Flags are cleared explicitly, and this is not tidiness.
        //
        // `CGEventSource(stateID: .combinedSessionState)` hands back events carrying whatever
        // modifiers are *physically held right now*. Expand a snippet while resting a finger on
        // Shift and the whole expansion arrives shouted; do it while holding Command and the
        // characters are interpreted as shortcuts instead — `⌘a` selects all, and the next one
        // replaces the document. `Paster.postCommandV` already sets its flags for the same reason.
        down.flags = []
        up.flags = []

        // Without the tag these re-enter our own tap and the matcher sees its own expansion as
        // typing — which for a snippet whose expansion contains its trigger would loop. The tap
        // skips tagged events centrally, before any feature sees them.
        EventTapService.tagAsSynthetic(down)
        EventTapService.tagAsSynthetic(up)

        let keyCode = down.getIntegerValueField(.keyboardEventKeycode)
        log.debug("posting keycode \(keyCode, privacy: .public), flags \(down.flags.rawValue, privacy: .public)")

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

}
