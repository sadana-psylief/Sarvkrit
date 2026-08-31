import CoreGraphics
import XCTest
@testable import Sarvkrit

final class WindowShortcutTests: XCTestCase {

    private func store() -> WindowShortcutStore {
        let defaults = UserDefaults(suiteName: "WindowShortcutTests-\(UUID().uuidString)")!
        return WindowShortcutStore(defaults: defaults)
    }

    // MARK: - Matching

    func testAShortcutMatchesItsOwnCombination() {
        let shortcut = WindowShortcut(keyCode: 123, modifiers: [.maskControl, .maskAlternate])
        XCTAssertTrue(shortcut.matches(keyCode: 123, flags: [.maskControl, .maskAlternate]))
    }

    func testMatchingIsExactNotASubset() {
        // ⌃⌥← must not fire on ⌃⌥⇧←, which belongs to another app.
        let shortcut = WindowShortcut(keyCode: 123, modifiers: [.maskControl, .maskAlternate])
        XCTAssertFalse(shortcut.matches(keyCode: 123, flags: [.maskControl, .maskAlternate, .maskShift]))
        XCTAssertFalse(shortcut.matches(keyCode: 123, flags: [.maskControl]))
        XCTAssertFalse(shortcut.matches(keyCode: 123, flags: []))
    }

    func testIrrelevantFlagsAreIgnored() {
        // Caps lock and the numeric-keypad bit ride along on real events; if they counted, a
        // binding would stop working the moment caps lock was on.
        let shortcut = WindowShortcut(keyCode: 123, modifiers: [.maskControl, .maskAlternate])
        XCTAssertTrue(shortcut.matches(
            keyCode: 123,
            flags: [.maskControl, .maskAlternate, .maskAlphaShift, .maskNumericPad]
        ))
    }

    // MARK: - Defaults

    func testArrowKeysAreBoundToHalvesByDefault() {
        let s = store()
        XCTAssertEqual(s.action(keyCode: 123, flags: [.maskControl, .maskAlternate]), .leftHalf)
        XCTAssertEqual(s.action(keyCode: 124, flags: [.maskControl, .maskAlternate]), .rightHalf)
        XCTAssertEqual(s.action(keyCode: 126, flags: [.maskControl, .maskAlternate]), .topHalf)
        XCTAssertEqual(s.action(keyCode: 125, flags: [.maskControl, .maskAlternate]), .bottomHalf)
    }

    func testAnUnboundCombinationMatchesNothing() {
        XCTAssertNil(store().action(keyCode: 123, flags: [.maskCommand]))
    }

    func testDefaultsDoNotCollideWithTheClipboardShortcuts() {
        // Clipboard owns ⌃⌥1–5 and ⌘⇧C globally. A collision here would silently break pasting —
        // whichever feature the tap reached first would swallow the key.
        let s = store()
        for digit in ClipboardHotkey.digitKeyCodes {
            XCTAssertNil(s.action(keyCode: digit, flags: [.maskControl, .maskAlternate]),
                         "⌃⌥ + digit belongs to the clipboard")
        }
        XCTAssertNil(s.action(keyCode: ClipboardHotkey.keyC, flags: [.maskCommand, .maskShift]))
    }

    func testNoTwoActionsShareADefaultShortcut() {
        let all = WindowShortcutStore.rectangleDefaults.values
        XCTAssertEqual(Set(all).count, all.count, "a duplicate default means one action can never fire")
    }

    // MARK: - Rebinding

    func testRebindingReplacesTheOldCombination() {
        let s = store()
        s.bind(.leftHalf, to: WindowShortcut(keyCode: 12, modifiers: [.maskCommand, .maskControl]))

        XCTAssertEqual(s.action(keyCode: 12, flags: [.maskCommand, .maskControl]), .leftHalf)
        XCTAssertNil(s.action(keyCode: 123, flags: [.maskControl, .maskAlternate]),
                     "the old combination should stop working")
    }

    func testTakingACombinationFromAnotherActionUnbindsThatOne() {
        // Two actions on one key means only one of them could ever fire; the other silently dies.
        let s = store()
        s.bind(.maximize, to: WindowShortcut(keyCode: 123, modifiers: [.maskControl, .maskAlternate]))

        XCTAssertEqual(s.action(keyCode: 123, flags: [.maskControl, .maskAlternate]), .maximize)
        XCTAssertNil(s.shortcut(for: .leftHalf))
    }

    func testABindingCanBeCleared() {
        let s = store()
        s.bind(.leftHalf, to: nil)
        XCTAssertNil(s.action(keyCode: 123, flags: [.maskControl, .maskAlternate]))
        XCTAssertNil(s.shortcut(for: .leftHalf))
    }

    func testBindingsSurviveARestart() {
        let suite = "WindowShortcutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = WindowShortcutStore(defaults: defaults)
        first.bind(.maximize, to: WindowShortcut(keyCode: 12, modifiers: [.maskCommand]))

        let second = WindowShortcutStore(defaults: defaults)
        XCTAssertEqual(second.action(keyCode: 12, flags: [.maskCommand]), .maximize)
    }

    func testResetRestoresTheDefaults() {
        let s = store()
        s.bind(.leftHalf, to: WindowShortcut(keyCode: 12, modifiers: [.maskCommand]))
        s.resetToDefaults()
        XCTAssertEqual(s.action(keyCode: 123, flags: [.maskControl, .maskAlternate]), .leftHalf)
    }

    // MARK: - Display

    func testShortcutsRenderInTheUsualMacOrder() {
        XCTAssertEqual(
            WindowShortcut(keyCode: 123, modifiers: [.maskControl, .maskAlternate]).displayString,
            "⌃⌥←"
        )
        XCTAssertEqual(WindowShortcut(keyCode: 36, modifiers: [.maskControl, .maskAlternate]).displayString,
                       "⌃⌥↩")
        XCTAssertEqual(WindowShortcut(keyCode: 8, modifiers: [.maskCommand, .maskShift]).displayString,
                       "⇧⌘C")
    }

    func testEveryDefaultBindingRendersReadably() {
        for (action, shortcut) in WindowShortcutStore.rectangleDefaults {
            XCTAssertFalse(shortcut.displayString.contains("Key "),
                           "\(action.title) renders as a raw keycode")
        }
    }

    // MARK: - Repeat policy

    func testOnlyNudgeAndResizeRepeatWhenHeld() {
        // Holding ⌃⌥← on an ultrawide would otherwise spin the third → half → two-thirds cycle
        // several times a second.
        XCTAssertTrue(WindowFeature.repeatable.contains(.moveLeft))
        XCTAssertTrue(WindowFeature.repeatable.contains(.makeLarger))
        XCTAssertFalse(WindowFeature.repeatable.contains(.leftHalf))
        XCTAssertFalse(WindowFeature.repeatable.contains(.maximize))
        XCTAssertFalse(WindowFeature.repeatable.contains(.restore))
    }
}
