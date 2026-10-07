import Foundation

/// How thirsty the menu bar icon looks. The escalation the user sees before anything pops up.
///
/// Expressed as an SF Symbol progression — `drop` → `drop.halffull` → `drop.fill` — because the menu
/// bar icon is template-rendered and must stay that way (see `MenuBarIconState`). A tint would have
/// been the obvious way to say "more urgent", and it would have opted the icon out of inverting on
/// a dark menu bar.
enum WaterThirst: Int, Comparable {
    /// Not due, or nothing to say.
    case none
    /// Due. The icon changes and nothing else happens.
    case gentle
    /// Still due, halfway to the one notification.
    case building
    /// The notification has been earned (sent, or held back by a meeting, a lock or Focus).
    case urgent

    static func < (lhs: WaterThirst, rhs: WaterThirst) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbolName: String {
        switch self {
        case .none: return "drop"
        case .gentle: return "drop"
        case .building: return "drop.halffull"
        case .urgent: return "drop.fill"
        }
    }
}

/// The user's choices that shape the schedule. All durations are real seconds; the feature scales
/// them in a DEBUG build so a day can be walked through in minutes.
struct WaterSettings: Equatable {
    var goalMilliliters = 2_000
    /// Minutes after local midnight.
    var activeStartMinutes = 9 * 60
    var activeEndMinutes = 19 * 60
    var dayStartHour = 4
    /// The shortest time between one reminder and the next, and after a drink before the first.
    var minimumGap: TimeInterval = 45 * 60
    /// The longest a drink-less stretch can go without a reminder, even when on pace.
    var maximumGap: TimeInterval = 2 * 60 * 60
    /// From the icon changing to the notification.
    var escalationDelay: TimeInterval = 20 * 60
    /// After coming back from a long absence, how long to wait before reminding.
    var returnGrace: TimeInterval = 5 * 60

    /// Everything time-shaped divided by `factor`. Used only by the DEBUG time-scale override.
    func compressed(by factor: Double) -> WaterSettings {
        guard factor > 1 else { return self }
        var copy = self
        copy.minimumGap /= factor
        copy.maximumGap /= factor
        copy.escalationDelay /= factor
        copy.returnGrace /= factor
        return copy
    }
}

/// What the schedule needs to know about right now. Everything is passed in — no clock, no
/// defaults, no system calls — so every rule below is a table-driven test.
struct WaterScheduleInput {
    var now: Date
    var settings: WaterSettings
    var consumedToday: Int
    var lastDrink: Date?
    /// When the last notification went out.
    var lastNotification: Date?
    /// Notifications sent since the last drink. Each one ignored doubles the spacing to the next.
    var ignoredNotifications = 0
    var snoozedUntil: Date?
    /// The start of a hydration day the user said "not today" to.
    var silencedDay: Date?
    /// A meeting, a locked screen, an idle Mac: the icon may change, nothing may pop up.
    var suppressed = false
    /// Set after coming back from a long absence: no notification before this.
    var graceUntil: Date?
}

struct WaterDecision: Equatable {
    var thirst: WaterThirst
    /// Send the notification now. The caller records it as sent, which pushes the next one away.
    var shouldNotify: Bool
    var goalMet: Bool
    /// The next moment the answer could change on its own. Nil means only an event can change it
    /// (a drink, a setting, a suppression ending).
    var recheckAt: Date?

    static func quiet(until date: Date?, goalMet: Bool = false) -> WaterDecision {
        WaterDecision(thirst: .none, shouldNotify: false, goalMet: goalMet, recheckAt: date)
    }
}

/// When to remind, and how loudly.
///
/// The shape of it is what people actually put up with:
///
/// - **Paced, not periodic.** You are reminded when you fall behind a straight line from nothing at
///   the start of your active hours to the goal at their end. Drinking ahead of the line buys you
///   silence. A fixed "every 45 minutes" clock is what gets reminder apps switched off.
/// - **A drink resets everything.** The gap is measured from the last drink, so drinking early
///   never earns a reminder five minutes later.
/// - **But never forgotten.** Even on pace, `maximumGap` without a drink earns a reminder: being
///   ahead at 11 doesn't mean you can go until 4.
/// - **Quiet first, loud once.** The icon changes, and only `escalationDelay` later — if nothing
///   was logged and nothing suppresses it — does one notification go out.
/// - **Ignored means back off.** Each unanswered notification doubles the spacing to the next one,
///   up to `maximumGap`. Logging anything resets it.
/// - **No backlog.** Coming back after a long absence earns a grace period and then a single
///   reminder, never one for every slot that passed while you were away.
/// - **Done means done.** At the goal, nothing more today.
enum WaterSchedule {
    static func decide(_ input: WaterScheduleInput, calendar: Calendar = .current) -> WaterDecision {
        let now = input.now
        let settings = input.settings
        let dayStart = HydrationDay.start(of: now, dayStartHour: settings.dayStartHour, calendar: calendar)
        let dayEnd = HydrationDay.end(of: now, dayStartHour: settings.dayStartHour, calendar: calendar)

        if input.consumedToday >= settings.goalMilliliters {
            return .quiet(until: dayEnd, goalMet: true)
        }
        if let silenced = input.silencedDay, silenced == dayStart {
            return .quiet(until: dayEnd)
        }

        guard let window = activeWindow(containingOrAfter: now, settings: settings, calendar: calendar) else {
            return .quiet(until: dayEnd)
        }
        if now < window.start { return .quiet(until: window.start) }

        if let snoozed = input.snoozedUntil, snoozed > now {
            return .quiet(until: snoozed)
        }

        // When the icon should change.
        let drinkAnchor = max(input.lastDrink ?? window.start, window.start)
        let caughtUpAt = paceCatchUp(consumed: input.consumedToday, window: window, goal: settings.goalMilliliters)
        let paceDue = max(drinkAnchor + settings.minimumGap, caughtUpAt)
        let longGapDue = drinkAnchor + settings.maximumGap
        let iconDue = min(paceDue, longGapDue)

        if iconDue >= window.end {
            // Nothing more today inside the window. Look again when the next one opens.
            return .quiet(until: nextWindowStart(after: now, settings: settings, calendar: calendar))
        }
        if now < iconDue { return .quiet(until: iconDue) }

        // When the notification should go out.
        var notifyAt = iconDue + settings.escalationDelay
        if let snoozed = input.snoozedUntil, snoozed > (input.lastNotification ?? .distantPast) {
            // Snooze is an explicit "ask me again at…", so it replaces the back-off rather than
            // adding to it: a 15-minute snooze that came back after 90 would be a broken promise.
            notifyAt = max(notifyAt, snoozed)
        } else if let last = input.lastNotification, last >= drinkAnchor {
            let doublings = Double(max(0, input.ignoredNotifications))
            let spacing = min(settings.minimumGap * pow(2, doublings), settings.maximumGap)
            notifyAt = max(notifyAt, last + spacing)
        }

        let halfway = iconDue + settings.escalationDelay / 2
        let notifiedSinceDue = (input.lastNotification ?? .distantPast) >= iconDue
        let thirst: WaterThirst
        if now >= notifyAt || notifiedSinceDue {
            thirst = .urgent
        } else if now >= halfway {
            thirst = .building
        } else {
            thirst = .gentle
        }

        let inGrace = input.graceUntil.map { now < $0 } ?? false
        let notifyInWindow = notifyAt < window.end
        let shouldNotify = now >= notifyAt && notifyInWindow && !input.suppressed && !inGrace

        var candidates: [Date] = [halfway, notifyAt, window.end]
        if let grace = input.graceUntil { candidates.append(grace) }
        let recheck = candidates.filter { $0 > now }.min()

        return WaterDecision(thirst: thirst, shouldNotify: shouldNotify, goalMet: false, recheckAt: recheck)
    }

    // MARK: - Pieces, internal for the tests

    /// The moment the pace line reaches what's already been drunk. In the past when behind.
    static func paceCatchUp(consumed: Int, window: DateInterval, goal: Int) -> Date {
        guard goal > 0 else { return window.end }
        let fraction = min(1, max(0, Double(consumed) / Double(goal)))
        return window.start + window.duration * fraction
    }

    /// How much should have been drunk by `now`, on a straight line through the active hours.
    static func expected(by now: Date, settings: WaterSettings, calendar: Calendar = .current) -> Int {
        guard let window = activeWindow(containingOrAfter: now, settings: settings, calendar: calendar),
              window.duration > 0 else { return 0 }
        let fraction = min(1, max(0, now.timeIntervalSince(window.start) / window.duration))
        return Int((Double(settings.goalMilliliters) * fraction).rounded())
    }

    /// Today's active hours when `now` is before their end, otherwise nil. Nil also for a window
    /// that isn't one — an end at or before the start.
    static func activeWindow(
        containingOrAfter now: Date, settings: WaterSettings, calendar: Calendar = .current
    ) -> DateInterval? {
        guard settings.activeEndMinutes > settings.activeStartMinutes else { return nil }
        let midnight = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .minute, value: settings.activeStartMinutes, to: midnight),
              let end = calendar.date(byAdding: .minute, value: settings.activeEndMinutes, to: midnight),
              now < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// The first active-hours start strictly after `now`.
    static func nextWindowStart(after now: Date, settings: WaterSettings, calendar: Calendar = .current) -> Date? {
        let midnight = calendar.startOfDay(for: now)
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: midnight),
                  let start = calendar.date(byAdding: .minute, value: settings.activeStartMinutes, to: day)
            else { continue }
            if start > now { return start }
        }
        return nil
    }
}
