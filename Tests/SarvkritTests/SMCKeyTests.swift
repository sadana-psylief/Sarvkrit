import XCTest
@testable import Sarvkrit

/// The four-character-code codec, which is the one place a typo turns into a silently wrong key.
final class SMCKeyTests: XCTestCase {

    func testAFourCharacterKeyPacksIntoItsASCIICode() {
        XCTAssertEqual(SMCKey("FNum")?.code, 0x464E_756D)
        XCTAssertEqual(SMCKey("F0Ac")?.code, 0x4630_4163)
    }

    func testTheCodeUnpacksBackIntoTheSameFourCharacters() {
        XCTAssertEqual(SMCKey("F0Md")?.description, "F0Md")
    }

    func testAKeyThatIsNotExactlyFourCharactersIsRejected() {
        XCTAssertNil(SMCKey("F0M"), "three characters is not an SMC key")
        XCTAssertNil(SMCKey("F0Mode"), "six characters is not an SMC key")
        XCTAssertNil(SMCKey(""), "the empty string is not an SMC key")
    }

    func testANonASCIIKeyIsRejected() {
        XCTAssertNil(SMCKey("F0M°"), "a degree sign does not fit in one SMC key byte")
    }

    func testTheFanKeyTableSpellsEachPerFanKey() {
        XCTAssertEqual(FanKey.actual(0)?.description, "F0Ac")
        XCTAssertEqual(FanKey.minimum(0)?.description, "F0Mn")
        XCTAssertEqual(FanKey.maximum(1)?.description, "F1Mx")
        XCTAssertEqual(FanKey.target(1)?.description, "F1Tg")
        XCTAssertEqual(FanKey.mode(9)?.description, "F9Md")
    }

    /// An SMC key is exactly four characters, so a tenth fan has no unambiguous spelling. No
    /// shipping Mac has one; a nil here must read as "not controllable", never as a malformed key.
    func testAFanIndexPastNineHasNoKey() {
        XCTAssertNil(FanKey.actual(10))
        XCTAssertNil(FanKey.mode(-1))
    }
}
