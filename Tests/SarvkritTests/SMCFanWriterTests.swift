import XCTest
@testable import Sarvkrit

/// The only code in the project that writes an SMC key.
///
/// It runs as root inside the helper, so everything here is about not trusting its input: the
/// percentage has already been clamped by the app, and is clamped again, from ranges the writer
/// reads itself rather than ranges it was told.
final class SMCFanWriterTests: XCTestCase {

    private final class Bench {
        var keys: [String: Double]
        private(set) var writes: [(key: String, value: Double)] = []
        init(_ keys: [String: Double]) { self.keys = keys }

        func writer() -> SMCFanWriter {
            SMCFanWriter(
                read: { [unowned self] in self.keys[$0.description] },
                write: { [unowned self] value, key in
                    self.writes.append((key.description, value))
                    self.keys[key.description] = value
                    return true
                })
        }
        func wrote(_ key: String) -> Double? { writes.last { $0.key == key }?.value }
    }

    private func twoFans() -> Bench {
        Bench(["FNum": 2,
               "F0Mn": 2317, "F0Mx": 6800,
               "F1Mn": 1180, "F1Mx": 4600])
    }

    func testHoldingTheFansSwitchesEachOneIntoForcedMode() {
        let bench = twoFans()
        XCTAssertTrue(bench.writer().hold(percent: 70))
        XCTAssertEqual(bench.wrote("F0Md"), 1)
        XCTAssertEqual(bench.wrote("F1Md"), 1)
    }

    /// Each fan gets the same fraction of *its own* range, which is the entire reason the wire
    /// protocol carries a percentage rather than an RPM.
    func testEachFanGetsTheSameFractionOfItsOwnRange() {
        let bench = twoFans()
        XCTAssertTrue(bench.writer().hold(percent: 70))
        XCTAssertEqual(try XCTUnwrap(bench.wrote("F0Tg")), 5455.1, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(bench.wrote("F1Tg")), 3574, accuracy: 0.1)
    }

    /// The app clamps before sending. This clamps again, because a root process cannot treat the
    /// number it was handed as having been checked.
    func testAnOutOfRangePercentageIsClampedRatherThanTrusted() {
        let bench = twoFans()
        XCTAssertTrue(bench.writer().hold(percent: 9000))
        XCTAssertEqual(bench.wrote("F0Tg"), 6800)

        let low = twoFans()
        XCTAssertTrue(low.writer().hold(percent: -9000))
        XCTAssertEqual(low.wrote("F0Tg"), 2317)
    }

    /// Zero percent is the fan's minimum. There is no number the wire protocol can carry that
    /// stops a fan, and this is the end of the chain where that has to remain true.
    func testZeroPercentIsTheMinimumAndNeverStopsTheFan() {
        let bench = twoFans()
        XCTAssertTrue(bench.writer().hold(percent: 0))
        XCTAssertEqual(bench.wrote("F0Tg"), 2317)
        XCTAssertEqual(bench.wrote("F1Tg"), 1180)
    }

    /// The range is read fresh on every hold rather than cached from the app, so a Mac that
    /// reports a different range than the app believes still gets a legal target.
    func testTheRangeIsReadFromTheSMCRatherThanTakenOnTrust() {
        let bench = twoFans()
        _ = bench.writer().hold(percent: 100)
        XCTAssertEqual(bench.wrote("F0Tg"), 6800)

        bench.keys["F0Mx"] = 4000
        _ = bench.writer().hold(percent: 100)
        XCTAssertEqual(bench.wrote("F0Tg"), 4000)
    }

    func testReleasingHandsEveryFanBackToMacOS() {
        let bench = twoFans()
        XCTAssertTrue(bench.writer().release())
        XCTAssertEqual(bench.wrote("F0Md"), 0)
        XCTAssertEqual(bench.wrote("F1Md"), 0)
    }

    /// A fan whose range the SMC will not report cannot be given a safe target, so it is left
    /// alone rather than guessed at.
    func testAFanWithNoReadableRangeIsLeftAlone() {
        let bench = Bench(["FNum": 1])
        XCTAssertFalse(bench.writer().hold(percent: 70))
        XCTAssertNil(bench.wrote("F0Tg"))
        XCTAssertNil(bench.wrote("F0Md"))
    }

    /// Releasing must work even then — it is the safe direction, and the one that runs when
    /// things have already gone wrong.
    func testAFanWithNoReadableRangeIsStillReleased() {
        let bench = Bench(["FNum": 1])
        XCTAssertTrue(bench.writer().release())
        XCTAssertEqual(bench.wrote("F0Md"), 0)
    }

    /// The case that matters most and was wrong: `release()` runs when something has *already*
    /// gone wrong, and an SMC that will not say how many fans there are is exactly that. Bailing
    /// out here leaves the fans forced and the helper exiting, which is the one outcome this
    /// whole design exists to prevent. Write the mode key blind instead.
    func testAnSMCThatWillNotSayHowManyFansThereAreIsStillReleased() {
        let bench = Bench([:])
        XCTAssertTrue(bench.writer().release())
        XCTAssertEqual(bench.wrote("F0Md"), 0)
        XCTAssertEqual(bench.wrote("F1Md"), 0)
    }

    func testAFanlessMacIsNothingToDoRatherThanAFailure() {
        let bench = Bench(["FNum": 0])
        XCTAssertTrue(bench.writer().release())
        XCTAssertTrue(bench.writes.isEmpty)
    }
}
