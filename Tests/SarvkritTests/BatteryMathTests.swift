import XCTest
@testable import Sarvkrit

/// Turning IOKit's battery registry values into watts.
///
/// This exists as a pure type because of one specific trap. `AppleSmartBattery` publishes
/// `Amperage` as a signed quantity, but it arrives through Core Foundation as an *unsigned* 64-bit
/// integer — so a discharging Mac reports 18446744073709551220 rather than −396. Multiplied by
/// voltage without reinterpretation that is not a slightly wrong wattage, it is roughly 2 × 10^17
/// watts, and it renders as a plausible-looking string in a menu bar.
///
/// The value in the first test is the literal reading taken from this Mac while planning.
final class BatteryMathTests: XCTestCase {

    // MARK: - The sign

    func testTheProbedDischargeValueReinterpretsAsNegativeMilliamps() {
        // Measured on an M2 Pro while unplugged: 2^64 − 18446744073709551220 == 396.
        XCTAssertEqual(BatteryMath.milliamps(rawAmperage: 18_446_744_073_709_551_220), -396)
    }

    func testChargingAmperageIsLeftPositive() {
        // Positive values arrive unmangled and must not be flipped by the reinterpretation.
        XCTAssertEqual(BatteryMath.milliamps(rawAmperage: 2_500), 2_500)
    }

    func testZeroAmperageIsZero() {
        XCTAssertEqual(BatteryMath.milliamps(rawAmperage: 0), 0)
    }

    func testTheReinterpretationIsExactAtTheBoundary() {
        // One below 2^63 is the largest genuinely positive reading; 2^63 itself is the most
        // negative. Getting this edge wrong would flip the sign of a plausible current.
        XCTAssertEqual(BatteryMath.milliamps(rawAmperage: UInt64(Int64.max)), Int(Int64.max))
        XCTAssertEqual(BatteryMath.milliamps(rawAmperage: UInt64.max), -1)
    }

    // MARK: - Watts

    func testWattsAreMilliampsTimesMillivolts() {
        // 396 mA at 11.582 V — again the readings measured on this Mac — is about 4.59 W out.
        let watts = BatteryMath.watts(milliamps: -396, millivolts: 11_582)
        XCTAssertEqual(try XCTUnwrap(watts), -4.586, accuracy: 0.001)
    }

    func testChargingProducesPositiveWatts() {
        let watts = BatteryMath.watts(milliamps: 2_500, millivolts: 12_000)
        XCTAssertEqual(try XCTUnwrap(watts), 30, accuracy: 0.001)
    }

    func testAMissingVoltageIsNilNotZeroWatts() {
        // A machine that reports no voltage tells us nothing about power draw. Zero would claim it
        // is drawing nothing, which is a different and false statement.
        XCTAssertNil(BatteryMath.watts(milliamps: -396, millivolts: 0))
    }

    func testIdleCurrentIsZeroWattsNotNil() {
        // A fully charged Mac on the adapter genuinely moves no current through the battery.
        XCTAssertEqual(BatteryMath.watts(milliamps: 0, millivolts: 11_582), 0)
    }
}
