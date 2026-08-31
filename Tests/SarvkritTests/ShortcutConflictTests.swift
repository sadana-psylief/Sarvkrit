import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The recorder's policy. This matters more than it looks: the tap **swallows** what it matches, so
/// a bad binding doesn't just fail to work — it takes the key away from every app on the system.
final class ShortcutConflictTests: XCTestCase {

    private func verdict(
        _ keyCode: Int64,
        _ modifiers: CGEventFlags,
        existing: [WindowAction: WindowShortcut] = [:],
        assigningTo action: WindowAction = .maximize
    ) -> ShortcutConflict.Verdict {
        ShortcutConflict.verdict(
            for: WindowShortcut(keyCode: keyCode, modifiers: modifiers),
            existing: existing,
            assigningTo: action
        )
    }

    // MARK: - Refusals

    func testABareKeyIsRefused() {
        // Binding "A" would snap a window on every A typed anywhere — and the letter would never
        // reach the app, because we swallow what we match.
        XCTAssertFalse(verdict(0, []).isAllowed)
        XCTAssertFalse(verdict(0, [.maskShift]).isAllowed, "shift alone is still typing")
    }

    func testOneRealModifierIsEnough() {
        XCTAssertTrue(verdict(0, [.maskControl]).isAllowed)
        XCTAssertTrue(verdict(0, [.maskCommand]).isAllowed)
        XCTAssertTrue(verdict(0, [.maskAlternate]).isAllowed)
        XCTAssertTrue(verdict(0, [.maskShift, .maskControl]).isAllowed)
    }

    func testTheDestructiveSystemShortcutsAreRefused() {
        XCTAssertFalse(verdict(12, [.maskCommand]).isAllowed, "⌘Q")
        XCTAssertFalse(verdict(13, [.maskCommand]).isAllowed, "⌘W")
        XCTAssertFalse(verdict(WindowShortcut.tabKey, [.maskCommand]).isAllowed, "⌘Tab")
        XCTAssertFalse(verdict(WindowShortcut.spaceKey, [.maskCommand]).isAllowed, "⌘Space")
    }

    func testShiftTabIsRefusedAlongsideCommandTab() {
        // ⌘⇧Tab walks the app switcher backwards; taking it breaks the same gesture.
        XCTAssertFalse(verdict(WindowShortcut.tabKey, [.maskCommand, .maskShift]).isAllowed)
    }

    func testEscapeIsRefusedWithAnyModifiers() {
        // The recorder itself uses Escape to cancel, so it could never be captured anyway.
        XCTAssertFalse(verdict(WindowShortcut.escapeKey, [.maskCommand]).isAllowed)
        XCTAssertFalse(verdict(WindowShortcut.escapeKey, [.maskControl, .maskAlternate]).isAllowed)
    }

    func testARefusalExplainsItself() {
        // A recorder that just rejects a key without saying why reads as broken.
        guard case .refused(let reason) = verdict(12, [.maskCommand]) else {
            return XCTFail("⌘Q should be refused")
        }
        XCTAssertTrue(reason.contains("⌘Q"))
    }

    // MARK: - Sarvkrit's own shortcuts

    func testClipboardShortcutsAreFlaggedButNotRefused() {
        // The user is entitled to prefer the window action — but not to find out later that
        // pasting stopped working.
        let result = verdict(ClipboardHotkey.digitKeyCodes[0], [.maskControl, .maskAlternate])
        XCTAssertTrue(result.isAllowed)
        guard case .conflictsWithFeature(let name) = result else {
            return XCTFail("⌃⌥1 belongs to the clipboard")
        }
        XCTAssertTrue(name.contains("Clipboard"))
    }

    func testTheClipboardPickerShortcutIsFlagged() {
        guard case .conflictsWithFeature = verdict(ClipboardHotkey.keyC, [.maskCommand, .maskShift])
        else { return XCTFail("⌘⇧C opens the picker") }
    }

    func testFinderCutAndPasteKeysAreFlagged() {
        guard case .conflictsWithFeature(let name) = verdict(CutPasteRewriter.keyX, [.maskCommand])
        else { return XCTFail("⌘X belongs to Finder Cut & Paste") }
        XCTAssertTrue(name.contains("Finder"))

        guard case .conflictsWithFeature = verdict(CutPasteRewriter.keyV, [.maskCommand])
        else { return XCTFail("⌘V belongs to Finder Cut & Paste") }
    }

    func testAPlainLetterWithCommandIsFineWhenNobodyClaimsIt() {
        guard case .available = verdict(37, [.maskCommand, .maskControl]) else {
            return XCTFail("⌃⌘L is unclaimed")
        }
    }

    // MARK: - Stealing from another window action

    func testTakingACombinationFromAnotherActionIsSurfaced() {
        // `bind` already steals silently; the recorder has to say so first.
        let existing: [WindowAction: WindowShortcut] = [
            .leftHalf: WindowShortcut(keyCode: 123, modifiers: [.maskControl, .maskAlternate])
        ]
        let result = verdict(123, [.maskControl, .maskAlternate],
                             existing: existing, assigningTo: .maximize)

        XCTAssertTrue(result.isAllowed)
        XCTAssertEqual(result, .stealsFromWindowAction(.leftHalf))
        XCTAssertEqual(result.message,
                       "Currently used by Left Half. Recording this will unbind it.")
    }

    func testRebindingAnActionToItsOwnShortcutIsNotAConflict() {
        let existing: [WindowAction: WindowShortcut] = [
            .leftHalf: WindowShortcut(keyCode: 123, modifiers: [.maskControl, .maskAlternate])
        ]
        XCTAssertEqual(
            verdict(123, [.maskControl, .maskAlternate], existing: existing, assigningTo: .leftHalf),
            .available
        )
    }

    func testAvailableHasNothingToSay() {
        XCTAssertNil(ShortcutConflict.Verdict.available.message)
    }

    // MARK: - The shipping defaults

    func testEveryDefaultBindingPassesItsOwnPolicy() {
        // A default the recorder would refuse would be indefensible.
        for (action, shortcut) in WindowShortcutStore.rectangleDefaults {
            let result = ShortcutConflict.verdict(
                for: shortcut,
                existing: WindowShortcutStore.rectangleDefaults,
                assigningTo: action
            )
            XCTAssertEqual(result, .available, "\(action.title) (\(shortcut.displayString))")
        }
    }
}
