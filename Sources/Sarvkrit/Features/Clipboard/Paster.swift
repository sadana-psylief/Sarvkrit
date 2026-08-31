import AppKit
import CoreGraphics
import Foundation
import os

/// Puts an entry back on the pasteboard and, optionally, presses ⌘V for you.
///
/// The delicate part isn't the paste, it's the focus dance: the app you were typing in must be
/// frontmost again *before* the keystroke arrives, or it lands somewhere else entirely.
struct Paster {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Clipboard")
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Writes the item to the pasteboard. Returns false when the entry can no longer be honoured —
    /// a file that has since moved, or a payload whose backing file is gone.
    @discardableResult
    func place(_ item: ClipboardItem, asPlainText: Bool, on pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()

        switch item.kind {
        case .text(let value):
            return pasteboard.setString(value, forType: .string)

        case .largeText(let fileName, _, _):
            guard let data = store.readPayload(fileName),
                  let value = String(data: data, encoding: .utf8) else { return false }
            return pasteboard.setString(value, forType: .string)

        case .richText(let fileName, let plain):
            // "Paste as plain text" is why `plain` is stored alongside: no conversion, no
            // dependence on the rtf file still being readable.
            if asPlainText { return pasteboard.setString(plain, forType: .string) }
            guard let rtf = store.readPayload(fileName) else {
                return pasteboard.setString(plain, forType: .string)
            }
            pasteboard.setData(rtf, forType: .rtf)
            return pasteboard.setString(plain, forType: .string)

        case .image(let fileName, _, _, _):
            guard let data = store.readPayload(fileName) else { return false }
            return pasteboard.setData(data, forType: .png)

        case .files(let paths):
            let urls = paths.map(URL.init(fileURLWithPath:))
            // A moved or deleted file can't be pasted; say so rather than pasting nothing.
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                return false
            }
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }

    /// Brings `app` back to the front, waits until it actually *is* front, then presses ⌘V.
    ///
    /// Polling rather than sleeping a fixed delay: activation takes an unpredictable amount of
    /// time, and a keystroke sent a moment too early goes to the wrong app — which for a paste
    /// means typing into whatever was underneath.
    func pasteIntoFrontmost(restoring app: NSRunningApplication?, timeout: TimeInterval = 0.6) {
        guard let app else {
            postCommandV()
            return
        }
        app.activate()

        let deadline = Date().addingTimeInterval(timeout)
        func attempt() {
            let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            if isFront || Date() >= deadline {
                if !isFront {
                    log.warning("target app never came forward; pasting anyway")
                }
                postCommandV()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: attempt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: attempt)
    }

    /// Synthesizes ⌘V, tagged so our own event tap passes it through untouched. Without the tag,
    /// `CutPasteFeature` would see a ⌘V in Finder and turn this paste into a file *move*.
    func postCommandV() {
        // Same hazard as `SnippetTyper.replace`: a test reaching this would paste into the user's
        // foreground app. No test does today; this keeps that true.
        guard !AppIdentity.isRunningTests else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKeyCode: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        EventTapService.tagAsSynthetic(down)
        EventTapService.tagAsSynthetic(up)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
