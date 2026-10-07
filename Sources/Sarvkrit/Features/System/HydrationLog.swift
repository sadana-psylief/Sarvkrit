import Foundation

/// One drink.
struct HydrationEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let milliliters: Int

    init(id: UUID = UUID(), date: Date, milliliters: Int) {
        self.id = id
        self.date = date
        self.milliliters = milliliters
    }
}

/// Where a hydration "day" begins and ends.
///
/// **Not midnight.** Someone working until 1 am who drinks a glass at 00:30 drank it on the day they
/// are still living, not on a new one that has just reset their progress to zero and will start
/// reminding them at 9. So the day turns over at `dayStartHour` (4 am by default), the way sleep
/// trackers do it.
enum HydrationDay {
    static func start(of date: Date, dayStartHour: Int, calendar: Calendar = .current) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -dayStartHour, to: date) ?? date
        let midnight = calendar.startOfDay(for: shifted)
        return calendar.date(byAdding: .hour, value: dayStartHour, to: midnight) ?? midnight
    }

    static func end(of date: Date, dayStartHour: Int, calendar: Calendar = .current) -> Date {
        let start = start(of: date, dayStartHour: dayStartHour, calendar: calendar)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        // Re-anchored rather than trusted: across a DST change "a day later" from 4 am is still 4 am,
        // but going through `start(of:)` makes that true by construction.
        return Self.start(of: nextDay.addingTimeInterval(60), dayStartHour: dayStartHour, calendar: calendar)
    }
}

/// Everything drunk, and the questions asked of it.
///
/// Pure: no clock, no disk. `HydrationStore` persists it and the feature asks it questions with
/// whatever `now` it was handed, which is what lets the tests walk a day across midnight.
///
/// Entries are kept in **the order they were logged**, not by date. That is what Undo means — the
/// last thing you tapped — and a backdated "I had one at lunch" entry would otherwise sort itself
/// into the middle and make Undo remove something else.
struct HydrationLog: Codable, Equatable {
    private(set) var entries: [HydrationEntry] = []

    /// Long enough for any chart the app draws, short enough that the file never grows unbounded on
    /// a Mac that is never restarted.
    static let retentionDays = 90

    @discardableResult
    mutating func add(milliliters: Int, at date: Date) -> HydrationEntry {
        let entry = HydrationEntry(date: date, milliliters: milliliters)
        entries.append(entry)
        return entry
    }

    /// Removes the most recently *logged* entry, whatever time it was logged for.
    @discardableResult
    mutating func undoLast() -> HydrationEntry? {
        entries.popLast()
    }

    mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    var lastLogged: HydrationEntry? { entries.last }

    /// The latest time anything was drunk — not the latest thing logged, which may be backdated.
    var lastDrink: Date? { entries.map(\.date).max() }

    func entries(onDayOf date: Date, dayStartHour: Int, calendar: Calendar = .current) -> [HydrationEntry] {
        let start = HydrationDay.start(of: date, dayStartHour: dayStartHour, calendar: calendar)
        let end = HydrationDay.end(of: date, dayStartHour: dayStartHour, calendar: calendar)
        return entries
            .filter { $0.date >= start && $0.date < end }
            .sorted { $0.date < $1.date }
    }

    func total(onDayOf date: Date, dayStartHour: Int, calendar: Calendar = .current) -> Int {
        entries(onDayOf: date, dayStartHour: dayStartHour, calendar: calendar)
            .reduce(0) { $0 + $1.milliliters }
    }

    /// One total per day, oldest first, ending with the day containing `now`. Days with nothing
    /// logged are present as zero — a gap in a bar chart reads as missing data, not as a dry day.
    func dailyTotals(
        days: Int, endingAt now: Date, dayStartHour: Int, calendar: Calendar = .current
    ) -> [(day: Date, milliliters: Int)] {
        let today = HydrationDay.start(of: now, dayStartHour: dayStartHour, calendar: calendar)
        return (0..<max(0, days)).reversed().map { offset in
            let probe = calendar.date(byAdding: .day, value: -offset, to: today)
                ?? today.addingTimeInterval(Double(-offset) * 86_400)
            // Probe an hour in, so a DST shift can't land the probe on the previous day.
            let day = HydrationDay.start(
                of: probe.addingTimeInterval(3_600), dayStartHour: dayStartHour, calendar: calendar)
            return (day, total(onDayOf: day, dayStartHour: dayStartHour, calendar: calendar))
        }
    }

    /// Drops anything older than the retention window. Returns whether anything went.
    @discardableResult
    mutating func prune(now: Date, calendar: Calendar = .current) -> Bool {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: now) else {
            return false
        }
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        return entries.count != before
    }
}

/// How volumes are shown. Storage is always millilitres; this is only ever a display choice.
enum VolumeUnit: String, CaseIterable, Identifiable {
    case milliliters
    case fluidOunces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .milliliters: return "Millilitres"
        case .fluidOunces: return "Fluid ounces"
        }
    }

    /// US customary fluid ounce. The imperial one differs by 4% and nobody choosing ounces on a Mac
    /// set to the UK is likely to mean it.
    static let millilitersPerOunce = 29.5735

    /// What a fresh install shows: ounces only where the locale measures in US units.
    static var localeDefault: VolumeUnit {
        Locale.current.measurementSystem == .us ? .fluidOunces : .milliliters
    }

    /// "250 ml", "1.5 L", "8 fl oz".
    func format(_ milliliters: Int) -> String {
        switch self {
        case .milliliters:
            if milliliters >= 1_000 {
                let liters = Double(milliliters) / 1_000
                return liters.formatted(.number.precision(.fractionLength(0...2))) + " L"
            }
            return "\(milliliters) ml"
        case .fluidOunces:
            let ounces = Double(milliliters) / Self.millilitersPerOunce
            return ounces.formatted(.number.precision(.fractionLength(0...1))) + " fl oz"
        }
    }

    /// The number alone, in this unit, for steppers and fields.
    func value(of milliliters: Int) -> Double {
        switch self {
        case .milliliters: return Double(milliliters)
        case .fluidOunces: return Double(milliliters) / Self.millilitersPerOunce
        }
    }

    func milliliters(from value: Double) -> Int {
        switch self {
        case .milliliters: return Int(value.rounded())
        case .fluidOunces: return Int((value * Self.millilitersPerOunce).rounded())
        }
    }
}
