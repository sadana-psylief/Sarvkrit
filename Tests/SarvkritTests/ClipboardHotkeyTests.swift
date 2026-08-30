import CoreGraphics
import XCTest
@testable import Sarvkrit

/// These shortcuts are **swallowed** — the app underneath never sees them. Matching too eagerly
/// means silently eating keystrokes from whatever the user is actually typing in, which is close to
/// impossible to diagnose from the outside.
final class ClipboardHotkeyTests: XCTestCase {
    private let commandShift: CGEventFlags = [.maskCommand, .maskShift]
    private let controlOption: CGEventFlags = [.maskControl, .maskAlternate]

    func testCommandShiftCOpensThePicker() {
        XCTAssertEqual(
            ClipboardHotkey.match(keyCode: ClipboardHotkey.keyC, flags: commandShift), .open)
    }

    func testControlOptionOneThroughFivePasteThatEntry() {
        // 1,2,3,4,5 — and note 5 is keycode 23, not 22. 22 is 6.
        let expected: [(Int64, Int)] = [(18, 1), (19, 2), (20, 3), (21, 4), (23, 5)]
        for (keyCode, index) in expected {
            XCTAssertEqual(
                ClipboardHotkey.match(keyCode: keyCode, flags: controlOption),
                .pasteIndex(index),
                "keycode \(keyCode) should be entry \(index)")
        }
    }

    // MARK: - What must NOT be taken globally

    func testCommandDigitsAreNeverClaimedGlobally() {
        // ⌘1–9 switches tabs in Safari, Chrome, Slack and nearly every tabbed app. Swallowing it
        // system-wide would break normal use within minutes.
        for keyCode in ClipboardHotkey.digitKeyCodes {
            XCTAssertNil(ClipboardHotkey.match(keyCode: keyCode, flags: .maskCommand))
        }
    }

    func testCommandShiftDigitsAreNoLongerClaimed() {
        // The old binding, deliberately retired in favour of ⌃⌥.
        for keyCode in ClipboardHotkey.digitKeyCodes {
            XCTAssertNil(ClipboardHotkey.match(keyCode: keyCode, flags: commandShift))
        }
    }

    func testControlDigitsAreNotClaimedBecauseSpacesUsesThem() {
        for keyCode in ClipboardHotkey.digitKeyCodes {
            XCTAssertNil(ClipboardHotkey.match(keyCode: keyCode, flags: .maskControl))
        }
    }

    func testOptionDigitsAreNotClaimedBecauseTheyTypeSymbols() {
        // ⌥1 types ¡ — swallowing it would break typing those characters.
        for keyCode in ClipboardHotkey.digitKeyCodes {
            XCTAssertNil(ClipboardHotkey.match(keyCode: keyCode, flags: .maskAlternate))
        }
    }

    // MARK: - Picker-only ⌘1–5

    func testCommandDigitsAreAvailableInsideThePicker() {
        // Safe here and only here: the picker holds keyboard focus, so nothing else is listening.
        let expected: [(Int64, Int)] = [(18, 1), (19, 2), (20, 3), (21, 4), (23, 5)]
        for (keyCode, index) in expected {
            XCTAssertEqual(ClipboardHotkey.pickerIndex(keyCode: keyCode, flags: .maskCommand), index)
        }
    }

    func testPickerDigitsRequireCommandAndNothingElse() {
        // A bare "1" is someone typing into the search field.
        XCTAssertNil(ClipboardHotkey.pickerIndex(keyCode: 18, flags: []))
        XCTAssertNil(ClipboardHotkey.pickerIndex(keyCode: 18, flags: [.maskCommand, .maskShift]))
        XCTAssertNil(ClipboardHotkey.pickerIndex(keyCode: 22, flags: .maskCommand), "6 is out of range")
    }

    func testKeycodeTwentyTwoIsSixAndIsNotAShortcut() {
        // The classic off-by-one in this keycode table.
        XCTAssertNil(ClipboardHotkey.match(keyCode: 22, flags: commandShift))
    }

    func testPlainCopyIsNotAShortcut() {
        // ⌘C must keep working, obviously — and so must ⌘X, which another feature rewrites.
        XCTAssertNil(ClipboardHotkey.match(keyCode: ClipboardHotkey.keyC, flags: .maskCommand))
        XCTAssertNil(ClipboardHotkey.match(keyCode: 7, flags: .maskCommand))
    }

    func testExtraModifiersDoNotMatch() {
        // ⌘⌥⇧C belongs to somebody else; swallowing it would break their app.
        for extra in [CGEventFlags.maskAlternate, .maskControl] {
            XCTAssertNil(ClipboardHotkey.match(
                keyCode: ClipboardHotkey.keyC, flags: commandShift.union(extra)))
        }
        XCTAssertNil(ClipboardHotkey.match(keyCode: 18, flags: controlOption.union(.maskCommand)))
    }

    func testMissingModifiersDoNotMatch() {
        // Typing "1" or "C" must never be swallowed.
        XCTAssertNil(ClipboardHotkey.match(keyCode: 18, flags: []))
        XCTAssertNil(ClipboardHotkey.match(keyCode: ClipboardHotkey.keyC, flags: []))
        XCTAssertNil(ClipboardHotkey.match(keyCode: 18, flags: .maskShift))
    }

    func testUnrelatedKeysWithTheRightModifiersDoNotMatch() {
        // ⌘⇧A, ⌘⇧6, ⌘⇧Z — all belong to the app underneath.
        for keyCode in [Int64(0), 22, 6] {
            XCTAssertNil(ClipboardHotkey.match(keyCode: keyCode, flags: commandShift))
            XCTAssertNil(ClipboardHotkey.match(keyCode: keyCode, flags: controlOption))
        }
    }

    func testCapsLockAndFunctionKeysAreIgnoredRatherThanBlockingAMatch() {
        // Modifier flags carry extra bits; only the four we care about are consulted.
        let withNoise = commandShift.union([.maskAlphaShift, .maskNonCoalesced])
        XCTAssertEqual(ClipboardHotkey.match(keyCode: ClipboardHotkey.keyC, flags: withNoise), .open)
    }
}
