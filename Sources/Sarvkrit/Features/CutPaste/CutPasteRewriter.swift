import CoreGraphics
import Foundation

/// The entire decision logic for Finder Cut & Paste, with no CGEvent, no pasteboard and no
/// AX dependency — so it is exhaustively unit-testable without a live event tap.
enum CutPasteRewriter {
    static let finderBundleID = "com.apple.finder"

    // ANSI virtual key codes.
    static let keyX: Int64 = 7
    static let keyC: Int64 = 8
    static let keyV: Int64 = 9

    enum Action: Equatable {
        /// Leave the event alone.
        case none
        /// ⌘X → ⌘C, and arm a pending cut.
        case rewriteCutToCopy
        /// ⌘V → ⌘⌥V, Finder's native "Move Item Here".
        case rewriteToMove
    }

    struct Input: Equatable {
        var keyCode: Int64
        var flags: CGEventFlags
        var frontmostBundleID: String?
        /// True between a ⌘X and the paste that consumes it.
        var cutPending: Bool
        /// Pasteboard change count sampled *after* Finder wrote the cut, or nil if that
        /// sample hasn't landed yet.
        var changeCountAtCut: Int?
        var currentChangeCount: Int
        /// True while renaming a file inline, where ⌘X must still cut text.
        var isTextFieldFocused: Bool
    }

    /// Does this keystroke even have the shape of ⌘X / ⌘V? Pure, and reads only fields already
    /// on the `CGEvent` — no IPC, no allocation. Every other key on the keyboard stops here.
    static func matchesShortcutShape(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == keyX || keyCode == keyV else { return false }
        return flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == .maskCommand
    }

    /// "Could this event possibly be ours?" — the gate in front of everything expensive.
    ///
    /// `frontmostBundleID` is an `@autoclosure` on purpose. This function sits in the path of
    /// every keystroke on the Mac, and the ordering here is the whole optimisation: a comment
    /// saying "cheap checks first" is exactly what failed before. Making the parameter lazy means
    /// the app lookup *cannot* be evaluated for an ordinary keystroke, whatever a caller writes.
    static func isCandidate(
        keyCode: Int64,
        flags: CGEventFlags,
        frontmostBundleID: @autoclosure () -> String?
    ) -> Bool {
        guard matchesShortcutShape(keyCode: keyCode, flags: flags) else { return false }
        return frontmostBundleID() == finderBundleID
    }

    static func action(for input: Input) -> Action {
        // ⌘X/⌘V already work everywhere in text. The only gap worth touching is Finder's
        // file operations, so everything else passes through untouched.
        guard input.frontmostBundleID == finderBundleID else { return .none }

        // Renaming a file inline is a text field inside Finder: ⌘X must cut the *text*.
        guard !input.isTextFieldFocused else { return .none }

        // Command and nothing else. ⌘⌥V is already Finder's move, ⌘⇧V is paste-and-match,
        // and hijacking either would break behaviour the user may already rely on.
        let modifiers = input.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard modifiers == .maskCommand else { return .none }

        switch input.keyCode {
        case keyX:
            return .rewriteCutToCopy

        case keyV:
            // Only move when the pasteboard still holds what the cut put there. If anything
            // copied since — another app, or the user — this is an ordinary paste, and
            // turning it into a move would relocate a file they meant to duplicate.
            guard input.cutPending,
                  let atCut = input.changeCountAtCut,
                  atCut == input.currentChangeCount
            else { return .none }
            return .rewriteToMove

        default:
            return .none
        }
    }
}
