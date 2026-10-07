import Foundation

/// Percent of a fan's own range, in both directions.
///
/// Percent rather than RPM is the unit the whole feature speaks, for two reasons. Raw RPM is not
/// portable — 3000 is loud on one model and idle on another — and the 14"/16" MacBook Pro has two
/// fans whose ranges differ, so one RPM figure applied to both would put them at different
/// fractions of their capability.
///
/// Pure, and shared with the root helper: the app clamps before sending and the helper clamps
/// again after reading the range itself, so neither side trusts the other's arithmetic.
enum FanSpeedMath {
    /// **Percent 0 maps to the fan's minimum, never to 0 RPM.** This is where "off never stops the
    /// fan" is enforced — by construction, in one function, rather than by a check somewhere that
    /// a later change could route around.
    ///
    /// Note that on Apple Silicon a minimum of 0 is itself a legitimate range: these fans really do
    /// stop when the Mac is cool. That is the SMC's decision to make and not ours, and it is why
    /// this function's promise is "never below the minimum" rather than "never zero".
    static func rpm(percent: Double, minimum: Double, maximum: Double) -> Double {
        guard maximum > minimum else { return minimum }
        let fraction = clamp(percent, 0, 100) / 100
        return clamp(minimum + fraction * (maximum - minimum), minimum, maximum)
    }

    /// `nil` when the fan has no headroom — dividing by that range would be a crash where the
    /// panel should show a dash.
    static func percent(rpm: Double, minimum: Double, maximum: Double) -> Double? {
        guard isControllable(minimum: minimum, maximum: maximum) else { return nil }
        return clamp((rpm - minimum) / (maximum - minimum) * 100, 0, 100)
    }

    static func isControllable(minimum: Double, maximum: Double) -> Bool {
        maximum > minimum
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value.isNaN ? low : min(max(value, low), high)
    }
}
