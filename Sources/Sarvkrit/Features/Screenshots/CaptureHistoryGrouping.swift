import Foundation

/// How the history browser groups captures.
///
/// Pure, so "what counts as yesterday" is a test rather than something you find out is wrong at
/// midnight. Calendar-day boundaries, not elapsed hours: a capture from 11pm last night is
/// "Yesterday" at 1am, and calling it "2 hours ago" would be technically true and useless.
enum CaptureHistoryGrouping {

    enum Section: Hashable, Comparable {
        case today
        case yesterday
        case earlierThisWeek
        case older

        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .earlierThisWeek: return "Earlier this week"
            case .older: return "Older"
            }
        }

        /// Display order, newest group first.
        var order: Int {
            switch self {
            case .today: return 0
            case .yesterday: return 1
            case .earlierThisWeek: return 2
            case .older: return 3
            }
        }

        static func < (a: Section, b: Section) -> Bool { a.order < b.order }
    }

    static func section(for date: Date, now: Date = Date(),
                        calendar: Calendar = .current) -> Section {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
            return .earlierThisWeek
        }
        return .older
    }

    /// Items grouped and ordered for display: newest section first, newest item first inside it.
    static func grouped(_ items: [CaptureHistoryItem], now: Date = Date(),
                        calendar: Calendar = .current) -> [(Section, [CaptureHistoryItem])] {
        Dictionary(grouping: items) { section(for: $0.createdAt, now: now, calendar: calendar) }
            .map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.0 < $1.0 }
    }

    /// "2 minutes ago", for the caption under a tile.
    static func relativeTime(for date: Date, now: Date = Date()) -> String {
        // Anything within a few seconds reads as "just now".
        //
        // Two reasons, and the second is the one that actually showed up: clock skew shouldn't
        // caption a fresh capture as "in 3 hours", and the formatter renders a sub-second gap as
        // **"in 0 sec"** — which is what every tile said on a shelf opened straight after a
        // capture. Guarding only on `date < now` doesn't help, because it is.
        guard now.timeIntervalSince(date) >= 5 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
