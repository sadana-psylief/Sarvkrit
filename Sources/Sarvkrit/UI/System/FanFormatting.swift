import Foundation

/// How a fan reading is written down.
///
/// Pure, and separate from the views, because the one genuinely tricky rule here is worth a test
/// rather than a code review: **a stopped fan is "0 rpm" and an unreadable one is a dash.** On
/// Apple Silicon the fans really do stop when the Mac is cool, so zero is the state they are in
/// most of the time — printing it as a dash would hide the common case behind the error case.
enum FanFormatting {
    static func rpm(_ value: Double?) -> String {
        guard let value else { return MetricFormatting.placeholder }
        return "\(Int(value.rounded())) rpm"
    }

    /// Where the fan sits in its own range, which is the number that is comparable between two
    /// fans with different ranges — and between two different Macs.
    static func percentOfRange(_ reading: FanReading) -> String {
        guard let rpm = reading.rpm, let minimum = reading.minimum, let maximum = reading.maximum,
              let percent = FanSpeedMath.percent(rpm: rpm, minimum: minimum, maximum: maximum)
        else { return MetricFormatting.placeholder }
        return MetricFormatting.percent(percent)
    }

    /// "2317 – 6800 rpm", or a dash when the SMC would not say what the range is.
    static func range(_ reading: FanReading) -> String {
        guard let minimum = reading.minimum, let maximum = reading.maximum else {
            return MetricFormatting.placeholder
        }
        return "\(Int(minimum.rounded())) – \(Int(maximum.rounded())) rpm"
    }

    /// Two fans get names rather than numbers, because "Fan 1" and "Fan 2" read as a count while
    /// "Left" and "Right" read as places. More than two and the count is the honest label.
    static func name(of index: Int, outOf total: Int) -> String {
        guard total == 2 else { return "Fan \(index + 1)" }
        return index == 0 ? "Left" : "Right"
    }
}
