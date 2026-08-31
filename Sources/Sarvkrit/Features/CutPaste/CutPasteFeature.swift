import AppKit
import CoreGraphics
import Foundation
import os

/// Makes ⌘X / ⌘V move files in Finder, the way they do on Windows.
///
/// Finder can already move files — it's just hidden behind ⌘C then ⌘⌥V. So rather than
/// implementing file moves ourselves, we rewrite the user's keystrokes into the ones Finder
/// already understands, and let Finder do the work (undo, progress, conflict prompts and all).
///
/// Events are mutated **in place** rather than swallowed and reposted. A reposted synthetic
/// event re-enters our own tap and needs source-tagging to avoid infinite recursion;
/// mutation sidesteps that entirely.
final class CutPasteFeature: EventTapFeature {
    let id = "finder-cut-paste"
    let category = FeatureCategory.keyboard
    let title = "Finder Cut & Paste"
    let summary = "Move files with ⌘X then ⌘V"
    let details = """
        Press ⌘X on files in Finder to mark them, then ⌘V in the destination to move them \
        there. Finder can already do this — it's just hidden behind ⌘C followed by ⌘⌥V — so \
        Sarvkrit translates the shortcut you expect into the one Finder listens for.

        Only Finder is affected. ⌘X while editing text, including renaming a file, still cuts \
        text as usual, and ⌘C followed by ⌘V still copies rather than moves.
        """
    let symbolName = "scissors"
    let shortcutHint: String? = "⌘X then ⌘V"

    var eventMask: CGEventMask { Sarvkrit.eventMask(.keyDown, .keyUp) }

    /// Set by ⌘X, cleared by the paste that consumes it or by anything else touching the
    /// pasteboard.
    private var cutPending = false
    /// Sampled after Finder has actually written the pasteboard — see `armCut()`.
    private var changeCountAtCut: Int?
    /// keyDowns this feature rewrote, awaiting their matching keyUps. See `PendingRewrites` for
    /// why this is not a `Set`.
    private var rewrittenKeyDowns = PendingRewrites()

    /// Cleared alongside `rewrittenKeyDowns`; see the note there.
    private var appSwitchObserver: NSObjectProtocol?

    /// Diagnostics for a stray keystroke. Records only rewrites this feature performs — never what
    /// the user types.
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "CutPaste")

    /// Called when something visible should be shown. Set by the UI layer so this type stays free
    /// of SwiftUI, the same way `ClipboardFeature` raises its picker.
    var showToast: ((String, String) -> Void)?
    /// Users who find the confirmation noisy can switch it off.
    var showsToasts: Bool {
        get { UserDefaults.standard.object(forKey: "cutPaste.showToasts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cutPaste.showToasts") }
    }

    func activate() {
        FrontmostAppMonitor.shared.start()
        FocusedRoleCache.shared.start()

        // A rewritten keyDown's keyUp is delivered to whoever has focus. Switching apps between the
        // two strands the keycode here forever, so the switch itself retires it.
        rewrittenKeyDowns.removeAll()
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rewrittenKeyDowns.removeAll()
        }
    }

    func deactivate() {
        FrontmostAppMonitor.shared.stop()
        FocusedRoleCache.shared.stop()
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
        cutPending = false
        changeCountAtCut = nil
        rewrittenKeyDowns.removeAll()
    }

    func handle(event: CGEvent, type: CGEventType) -> EventDecision {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            applyMatchingKeyUp(event: event, keyCode: keyCode)
            return .pass
        }
        guard type == .keyDown else { return .pass }

        // The gate. `frontmostBundleID` is lazy, so for an ordinary keystroke — which is very
        // nearly all of them — this costs two integer comparisons and nothing else.
        let flags = event.flags
        guard CutPasteRewriter.isCandidate(
            keyCode: keyCode,
            flags: flags,
            frontmostBundleID: FrontmostAppMonitor.shared.bundleID
        ) else {
            invalidateCutIfPasteboardMovedOn()
            return .pass
        }
        let frontmost = FrontmostAppMonitor.shared.bundleID

        let input = CutPasteRewriter.Input(
            keyCode: keyCode,
            flags: flags,
            frontmostBundleID: frontmost,
            cutPending: cutPending,
            changeCountAtCut: changeCountAtCut,
            currentChangeCount: NSPasteboard.general.changeCount,
            // A cached read. Asking AX directly here cost up to half a second *inside the event
            // tap*, which is system-wide input latency rather than merely our own — see
            // `FocusedRoleCache`. Unknown resolves to `true`, which is the harmless direction:
            // ⌘X passes through untouched instead of turning into a ⌘C that copies the file.
            isTextFieldFocused: FocusedRoleCache.shared.isTextFieldFocused ?? true
        )

        switch CutPasteRewriter.action(for: input) {
        case .none:
            invalidateCutIfPasteboardMovedOn()
            return .pass

        case .rewriteCutToCopy:
            log.debug("rewriting keycode \(keyCode, privacy: .public) to C (cut becomes copy)")
            event.setIntegerValueField(.keyboardEventKeycode, value: CutPasteRewriter.keyC)
            rewrittenKeyDowns.record(CutPasteRewriter.keyX)
            armCut()
            return .pass

        case .rewriteToMove:
            event.flags.insert(.maskAlternate)
            rewrittenKeyDowns.record(CutPasteRewriter.keyV)
            clearCut()
            toast("Moved", symbol: "checkmark.circle.fill")
            return .pass
        }
    }

    private func applyMatchingKeyUp(event: CGEvent, keyCode: Int64) {
        guard rewrittenKeyDowns.consume(keyCode) else { return }
        log.debug("rewriting the matching keyUp for keycode \(keyCode, privacy: .public)")
        switch keyCode {
        case CutPasteRewriter.keyX:
            event.setIntegerValueField(.keyboardEventKeycode, value: CutPasteRewriter.keyC)
        case CutPasteRewriter.keyV:
            event.flags.insert(.maskAlternate)
        default:
            break
        }
    }

    /// Finder writes the pasteboard **in its own process**, asynchronously, after it receives
    /// the ⌘C we just handed it. Sampling `changeCount` now would capture the stale pre-cut
    /// value, and the next legitimate copy would then look "unchanged" — turning a paste the
    /// user meant as a copy into a move. So the sample waits for Finder to land.
    ///
    /// Until it lands, `changeCountAtCut` is nil and `CutPasteRewriter` declines to move,
    /// which degrades to an ordinary paste. That's the safe direction to fail.
    private func armCut() {
        cutPending = true
        changeCountAtCut = nil
        let before = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.cutPending else { return }
            self.changeCountAtCut = NSPasteboard.general.changeCount

            // The confirmation is deliberately fired *here* rather than at the moment ⌘X was
            // pressed. ⌘X in Finder with nothing selected just beeps and writes nothing — showing
            // "press ⌘V to move" for a cut that never happened would be a lie. A changed count is
            // proof Finder actually put something on the pasteboard.
            guard self.changeCountAtCut != before else { return }
            self.toast("Cut — press ⌘V where you want it", symbol: "scissors")
        }
    }

    /// A plain ⌘C, or anything else claiming the pasteboard, retires the pending cut so a
    /// later ⌘V pastes a copy instead of moving files the user meant to duplicate.
    private func invalidateCutIfPasteboardMovedOn() {
        guard cutPending, let atCut = changeCountAtCut,
              NSPasteboard.general.changeCount != atCut else { return }
        clearCut()
    }

    private func toast(_ message: String, symbol: String) {
        guard showsToasts else { return }
        // Never from the event tap thread — presenting a window there would stall input.
        DispatchQueue.main.async { self.showToast?(message, symbol) }
    }

    private func clearCut() {
        cutPending = false
        changeCountAtCut = nil
    }

}
