import XCTest
@testable import Sarvkrit

final class FanFormattingTests: XCTestCase {

    /// The rule the whole panel hangs on. On Apple Silicon a cool Mac genuinely stops its fans,
    /// so zero is the state they are in most of the time — printing it as a dash would hide the
    /// common case behind the one that means something went wrong.
    func testAStoppedFanReadsZeroAndAnUnreadableOneReadsADash() {
        XCTAssertEqual(FanFormatting.rpm(0), "0 rpm")
        XCTAssertEqual(FanFormatting.rpm(nil), "—")
    }

    func testASpeedIsRoundedToWholeRPM() {
        XCTAssertEqual(FanFormatting.rpm(2316.6), "2317 rpm")
    }

    func testPercentIsOfTheFansOwnRangeNotOfItsMaximum() {
        let fan = FanReading(index: 0, rpm: 4558.5, minimum: 2317, maximum: 6800)
        XCTAssertEqual(FanFormatting.percentOfRange(fan), "50%")
    }

    func testPercentIsADashWhenTheRangeIsUnknown() {
        XCTAssertEqual(FanFormatting.percentOfRange(FanReading(index: 0, rpm: 2400)), "—")
    }

    func testTheRangeReadsAsASpan() {
        let fan = FanReading(index: 0, rpm: 2400, minimum: 2317, maximum: 6800)
        XCTAssertEqual(FanFormatting.range(fan), "2317 – 6800 rpm")
    }

    /// Two fans get places rather than numbers: "Fan 1" and "Fan 2" read as a count, which is not
    /// what someone looking at a two-fan MacBook Pro wants to know.
    func testTwoFansAreNamedLeftAndRight() {
        XCTAssertEqual(FanFormatting.name(of: 0, outOf: 2), "Left")
        XCTAssertEqual(FanFormatting.name(of: 1, outOf: 2), "Right")
    }

    func testAnyOtherNumberOfFansIsCounted() {
        XCTAssertEqual(FanFormatting.name(of: 0, outOf: 1), "Fan 1")
        XCTAssertEqual(FanFormatting.name(of: 2, outOf: 3), "Fan 3")
    }
}
