import Foundation

/// Every number the monitor shows on screen is rendered here.
///
/// It exists as one pure enum for two reasons. Formatting is where a monitor's lies live — showing
/// `0` for a reading that is actually unknown is the easiest way to mislead someone about their own
/// machine — and the menu bar punishes width changes, since three unexpected characters shove every
/// other item along. Both are testable only if the rules sit apart from the sampling.
enum MetricFormatting {

    /// Shown wherever a reading genuinely isn't known: after a wake, on a desktop with no battery,
    /// before the second sample of a rate. Deliberately not "0".
    static let placeholder = "—"

    // MARK: - Bytes

    /// Binary units, matching the kernel's own accounting and what Activity Monitor puts on screen.
    /// Decimal units would leave Sarvkrit and Activity Monitor disagreeing about the same number.
    private static let scales: [(threshold: Double, suffix: String)] = [
        (1_099_511_627_776, "TB"), (1_073_741_824, "GB"), (1_048_576, "MB"), (1_024, "KB"),
    ]

    static func bytes(_ value: UInt64) -> String {
        let value = Double(value)
        for scale in scales where value >= scale.threshold {
            // Always one decimal above a kilobyte: a value alternating between "9 GB" and "9.7 GB"
            // resizes the menu bar item on every tick.
            return String(format: "%.1f %@", value / scale.threshold, scale.suffix)
        }
        return "\(UInt64(value)) B"
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value else { return placeholder }
        return bytes(UInt64(max(0, value))) + "/s"
    }

    // MARK: - Percentages

    static func percent(_ value: Double?) -> String {
        guard let value else { return placeholder }
        // Clamped because tick-delta arithmetic can overshoot as a core comes online, and a Gauge
        // handed 118% draws outside its own track.
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }

    // MARK: - Watts

    /// The sign carries the message — which way the energy is going — so it is always explicit.
    ///
    /// A typographic minus (U+2212), not a hyphen: this sits directly beside digits in the menu
    /// bar's proportional font, where a hyphen reads as too short and sits too low.
    static func watts(_ value: Double?) -> String {
        guard let value else { return placeholder }
        // Round before testing the sign, or a draw of −0.04 W renders as "−0.0 W".
        let rounded = (value * 10).rounded() / 10
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "\u{2212}" : "")
        return String(format: "%@%.1f W", sign, abs(rounded))
    }

    // MARK: - Time remaining

    /// IOKit reports the estimate in whole minutes, using `-1` while it is still working it out and
    /// `0` when there is no estimate at all. Neither is a duration — rendering them arithmetically
    /// is how "-1:-1" ends up on screen.
    static func duration(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return placeholder }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
