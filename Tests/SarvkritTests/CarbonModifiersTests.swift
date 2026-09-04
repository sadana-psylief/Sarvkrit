import Carbon.HIToolbox
import XCTest
@testable import Sarvkrit

/// Asserted against the literal Carbon constants rather than against a re-derivation of the
/// function under test — otherwise the test would pass with the mapping inverted, which is
/// precisely the mistake it exists to catch.
final class CarbonModifiersTests: XCTestCase {

    func testEachModifierMapsToItsOwnCarbonMask() {
        XCTAssertEqual(CarbonModifiers.from(.maskCommand), UInt32(cmdKey))
        XCTAssertEqual(CarbonModifiers.from(.maskShift), UInt32(shiftKey))
        XCTAssertEqual(CarbonModifiers.from(.maskAlternate), UInt32(optionKey))
        XCTAssertEqual(CarbonModifiers.from(.maskControl), UInt32(controlKey))
    }

    func testTheCombinationThisFeatureActuallyUses() {
        // ⌃⇧, the family every capture shortcut lives in.
        XCTAssertEqual(CarbonModifiers.from([.maskControl, .maskShift]),
                       UInt32(controlKey | shiftKey))
    }

    func testAllFourTogether() {
        XCTAssertEqual(
            CarbonModifiers.from([.maskCommand, .maskShift, .maskAlternate, .maskControl]),
            UInt32(cmdKey | shiftKey | optionKey | controlKey))
    }

    func testNoModifiersIsZero() {
        XCTAssertEqual(CarbonModifiers.from([]), 0)
    }

    func testRawEventFlagBitsNeverLeakThrough() {
        // The actual bug this guards: CGEventFlags.maskCommand is 0x100000, cmdKey is 0x0100.
        // Handing the former to RegisterEventHotKey registers something else entirely.
        XCTAssertNotEqual(CarbonModifiers.from(.maskCommand),
                          UInt32(CGEventFlags.maskCommand.rawValue))
        XCTAssertLessThan(CarbonModifiers.from(
            [.maskCommand, .maskShift, .maskAlternate, .maskControl]), 0x10000)
    }

    func testItRoundTrips() {
        for flags: CGEventFlags in [[], [.maskCommand], [.maskControl, .maskShift],
                                    [.maskCommand, .maskAlternate],
                                    [.maskCommand, .maskShift, .maskAlternate, .maskControl]] {
            XCTAssertEqual(CarbonModifiers.toEventFlags(CarbonModifiers.from(flags)), flags)
        }
    }

    func testIrrelevantFlagsAreDropped() {
        // Caps lock and the numeric-keypad bit vary between keyboards; carrying them into a
        // registration would make the shortcut fail on some machines and not others.
        XCTAssertEqual(CarbonModifiers.from([.maskControl, .maskAlphaShift, .maskNumericPad]),
                       UInt32(controlKey))
    }
}
