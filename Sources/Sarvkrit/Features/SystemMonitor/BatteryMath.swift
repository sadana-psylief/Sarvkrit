import Foundation

/// Turns `AppleSmartBattery`'s registry values into watts.
///
/// Separate and pure because of one trap. `Amperage` is a signed quantity that reaches Swift as an
/// unsigned 64-bit integer, so a discharging Mac reads as 18446744073709551220 rather than −396.
/// Multiplied by voltage without reinterpretation that is not a slightly wrong wattage — it is
/// about 2 × 10^17 W, and it formats into a perfectly plausible-looking menu bar string.
///
/// Reinterpreting the bit pattern also makes the reader indifferent to which representation Core
/// Foundation hands back: a `CFNumber` built as a signed −396 and one printed by `ioreg` as the
/// unsigned equivalent have the same 64 bits, so both arrive here and leave as −396.
enum BatteryMath {
    static func milliamps(rawAmperage: UInt64) -> Int {
        Int(Int64(bitPattern: rawAmperage))
    }

    /// Negative while discharging, positive while charging, `nil` when the voltage is unknown.
    ///
    /// A missing voltage must not become zero watts: zero claims the battery is moving no power,
    /// which is a different and false statement from having no reading.
    static func watts(milliamps: Int, millivolts: Int) -> Double? {
        guard millivolts > 0 else { return nil }
        return Double(milliamps) / 1_000 * Double(millivolts) / 1_000
    }

    /// How much of its original charge the battery still holds, as a percentage.
    ///
    /// This is the number System Settings calls Maximum Capacity, and it comes from
    /// `NominalChargeCapacity ÷ DesignCapacity`. Both are real mAh figures, unlike `MaxCapacity`,
    /// which on Apple Silicon is already a percentage and always reads 100 — using it would give a
    /// battery health of 100% on every Mac forever, and look entirely convincing doing it.
    ///
    /// Not clamped upward. A new battery genuinely reports slightly over its design capacity, and
    /// 102% is the truth; capping it at 100 would hide a real reading to make the number tidier.
    static func healthPercent(nominalCapacity: Int?, designCapacity: Int?) -> Double? {
        guard let nominalCapacity, let designCapacity, designCapacity > 0, nominalCapacity > 0
        else { return nil }
        return Double(nominalCapacity) / Double(designCapacity) * 100
    }

    /// `AppleSmartBattery` reports temperature in hundredths of a degree Celsius.
    ///
    /// Guarded rather than converted blindly: the key is absent on a desktop and reads zero on a
    /// battery the SMC has not yet talked to, and −273°C on a menu panel would be a memorable bug.
    static func celsius(rawTemperature: Int?) -> Double? {
        guard let rawTemperature, rawTemperature > 0 else { return nil }
        return Double(rawTemperature) / 100
    }
}
