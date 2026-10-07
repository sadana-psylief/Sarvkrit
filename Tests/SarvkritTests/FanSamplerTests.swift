import XCTest
@testable import Sarvkrit

/// What the SMC's answers mean, tested without an SMC.
///
/// `FanSampler` takes its key reads as a closure for exactly this reason: the interesting
/// decisions here — no fans versus no answer, a mode key that is absent versus one that reads
/// zero — are the ones that cannot be reproduced on the machine running the suite.
final class FanSamplerTests: XCTestCase {

    /// A stub SMC: a key table in, reads out.
    private func sampler(_ values: [String: Double]) -> FanSampler {
        FanSampler { key in values[key.description] }
    }

    /// Every Apple Silicon MacBook Air answers zero here. That is a fact about the machine, and
    /// the panel must say so in a sentence rather than showing a failure.
    func testAMacReportingNoFansIsFanlessRatherThanUnreadable() {
        XCTAssertEqual(sampler(["FNum": 0]).read(), .fanless)
    }

    /// Not the same thing at all: the SMC did not answer. This one really is an error.
    func testAMacWhoseFanCountCannotBeReadIsUnreadable() {
        XCTAssertEqual(sampler([:]).read(), .unreadable)
    }

    func testEachFanIsReportedWithItsOwnSpeedAndRange() {
        let hardware = sampler([
            "FNum": 2,
            "F0Ac": 2400, "F0Mn": 2317, "F0Mx": 6800,
            "F1Ac": 2450, "F1Mn": 2350, "F1Mx": 6900,
        ]).read()

        guard case let .fans(fans) = hardware else { return XCTFail("expected two fans") }
        XCTAssertEqual(fans.count, 2)
        XCTAssertEqual(fans[0], FanReading(index: 0, rpm: 2400, minimum: 2317, maximum: 6800))
        XCTAssertEqual(fans[1], FanReading(index: 1, rpm: 2450, minimum: 2350, maximum: 6900))
    }

    /// Measured on a Mac14,9 at idle: these fans genuinely stop. Zero is the reading, not the
    /// absence of one, and conflating the two would hide the state the fans are in most often.
    func testAStoppedFanReportsZeroRatherThanNoReading() {
        let hardware = sampler(["FNum": 1, "F0Ac": 0, "F0Mn": 2317, "F0Mx": 6800]).read()
        guard case let .fans(fans) = hardware else { return XCTFail("expected one fan") }
        XCTAssertEqual(fans[0].rpm, 0)
    }

    func testAFanHeldByTheModeKeyIsReportedAsForced() {
        let hardware = sampler(["FNum": 1, "F0Md": 1]).read()
        guard case let .fans(fans) = hardware else { return XCTFail("expected one fan") }
        XCTAssertEqual(fans[0].isForced, true)
    }

    /// A Mac with no mode key cannot tell us who is driving. That must read as "unknown", never
    /// as "not forced" — the difference decides whether we offer to release a stranded fan.
    func testAMacWithNoModeKeyReportsForcedAsUnknown() {
        let hardware = sampler(["FNum": 1, "F0Ac": 2400]).read()
        guard case let .fans(fans) = hardware else { return XCTFail("expected one fan") }
        XCTAssertNil(fans[0].isForced)
    }

    /// An SMC key has one digit for the index, so a Mac claiming more fans than that has more
    /// fans than we can address. Report the ones we can reach rather than inventing key names.
    func testAFanCountBeyondWhatAKeyCanSpellIsTruncated() {
        let hardware = sampler(["FNum": 12]).read()
        guard case let .fans(fans) = hardware else { return XCTFail("expected fans") }
        XCTAssertEqual(fans.count, 10)
    }

    func testAFanWhoseRangeIsUnreadableIsNotControllable() {
        let hardware = sampler(["FNum": 1, "F0Ac": 2400]).read()
        guard case let .fans(fans) = hardware else { return XCTFail("expected one fan") }
        XCTAssertFalse(fans[0].isControllable)
    }
}
