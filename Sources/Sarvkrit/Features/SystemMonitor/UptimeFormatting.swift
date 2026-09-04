import Foundation

/// How long the Mac has been up, in the shortest form that is still true.
///
/// Pure and separate for the usual reason: the awkward cases are all in the rounding, and a
/// function that reads the clock cannot be given a two-day uptime to format on demand.
enum UptimeFormatting {
    /// Renders seconds as "2d 15h", "15h 4m" or "42m".
    ///
    /// Two units, never three: "2d 15h 41m" is longer than the line has room for and the minutes
    /// carry no information at that scale. Below a minute it says "just now" rather than counting
    /// seconds — a Mac that has been up for eight seconds is not something anyone is measuring.
    static func string(uptime seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "just now"
    }

    static func current() -> String {
        string(uptime: ProcessInfo.processInfo.systemUptime)
    }
}
