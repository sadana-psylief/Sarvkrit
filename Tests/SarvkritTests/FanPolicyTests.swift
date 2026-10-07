import XCTest
@testable import Sarvkrit

/// The whole of the control decision, as a truth table.
///
/// `isEngaged` is a parameter rather than state held inside the type, which is what makes every
/// row below one call with no setup — the `KeepAwakeState` pattern.
final class FanPolicyTests: XCTestCase {
    private let curve = FanCurve(thresholdCelsius: 75, targetPercent: 70, hysteresisCelsius: 4)

    // MARK: - Watching only

    func testWatchingOnlyNeverHoldsTheFan() {
        XCTAssertEqual(
            FanPolicy.command(mode: .monitor, celsius: 90, isEngaged: false),
            .release(.notControlling))
    }

    /// Even mid-ramp. Switching the mode back to watching is a request to let go.
    func testWatchingOnlyLetsGoOfAFanItWasHolding() {
        XCTAssertEqual(
            FanPolicy.command(mode: .monitor, celsius: 90, isEngaged: true),
            .release(.notControlling))
    }

    // MARK: - The ceiling, which outranks the user

    /// At this temperature Apple's controller is coordinating both fans, the power delivery and
    /// the frequency governor. A speed someone pinned by hand is strictly worse than getting out
    /// of the way — so this rule beats manual mode, which is the only rule that does.
    func testTheHardCeilingReleasesEvenAFanTheUserPinnedByHand() {
        XCTAssertEqual(
            FanPolicy.command(mode: .manual(percent: 30), celsius: 95, isEngaged: true),
            .release(.overCeiling))
    }

    func testTheHardCeilingReleasesARampedFanToo() {
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(curve), celsius: 99, isEngaged: true),
            .release(.overCeiling))
    }

    func testTheCeilingIsNotConfigurable() {
        // If this becomes a setting, it stops being a safety net and becomes another way to get
        // it wrong. Pinned so the change has to be deliberate.
        XCTAssertEqual(FanPolicy.hardCeilingCelsius, 95)
    }

    // MARK: - Manual

    func testManualHoldsWhateverSpeedWasAskedFor() {
        XCTAssertEqual(
            FanPolicy.command(mode: .manual(percent: 40), celsius: 60, isEngaged: false),
            .hold(percent: 40))
    }

    /// Manual needs no temperature to do its job, so a Mac whose sensors we cannot read still
    /// gets manual control — it just has no ceiling, which is why the UI says so.
    func testManualStillWorksWithNoTemperatureReading() {
        XCTAssertEqual(
            FanPolicy.command(mode: .manual(percent: 40), celsius: nil, isEngaged: false),
            .hold(percent: 40))
    }

    // MARK: - The ramp

    func testTheRampEngagesAtItsThreshold() {
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(curve), celsius: 75, isEngaged: false),
            .hold(percent: 70))
    }

    func testTheRampStaysOutJustBelowItsThreshold() {
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(curve), celsius: 74.9, isEngaged: false),
            .release(.belowThreshold))
    }

    /// The hysteresis band. Without it a Mac sitting at 75.0 °C toggles the fan every sample and
    /// sounds broken — which is a worse failure than running slightly warm.
    func testAnEngagedRampHoldsOnThroughTheHysteresisBand() {
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(curve), celsius: 72, isEngaged: true),
            .hold(percent: 70))
    }

    func testAnEngagedRampLetsGoOnceItIsBelowTheBand() {
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(curve), celsius: 70.9, isEngaged: true),
            .release(.belowThreshold))
    }

    /// The exact edge of the band, pinned because `>=` versus `>` here is the difference between
    /// a fan that settles and one that oscillates.
    func testTheBottomOfTheHysteresisBandIsInclusive() {
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(curve), celsius: 71, isEngaged: true),
            .hold(percent: 70))
    }

    /// Guessing a fan speed from a temperature we do not have is worse than not ramping.
    func testTheRampDoesNothingWithNoTemperatureReading() {
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(curve), celsius: nil, isEngaged: true),
            .release(.noTemperature))
    }

    func testARampTargetOutsideZeroToOneHundredIsClamped() {
        let silly = FanCurve(thresholdCelsius: 75, targetPercent: 140, hysteresisCelsius: 4)
        XCTAssertEqual(
            FanPolicy.command(mode: .automatic(silly), celsius: 80, isEngaged: false),
            .hold(percent: 100))
    }
}
