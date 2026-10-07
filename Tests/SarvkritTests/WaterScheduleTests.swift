import XCTest
@testable import Sarvkrit

/// The rules for when a water reminder fires, walked through a fixed day.
///
/// Defaults throughout: 2 L across 09:00–19:00 (200 ml an hour on the pace line), 45-minute minimum
/// gap, 2-hour maximum, 20 minutes from icon to notification, 5-minute grace after an absence. UTC,
/// so the suite means the same thing on every machine.
final class WaterScheduleTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func decide(
        _ now: Date,
        consumed: Int = 0,
        lastDrink: Date? = nil,
        lastNotification: Date? = nil,
        ignored: Int = 0,
        snoozedUntil: Date? = nil,
        silencedDay: Date? = nil,
        suppressed: Bool = false,
        graceUntil: Date? = nil,
        settings: WaterSettings = WaterSettings()
    ) -> WaterDecision {
        WaterSchedule.decide(WaterScheduleInput(
            now: now, settings: settings, consumedToday: consumed, lastDrink: lastDrink,
            lastNotification: lastNotification, ignoredNotifications: ignored,
            snoozedUntil: snoozedUntil, silencedDay: silencedDay, suppressed: suppressed,
            graceUntil: graceUntil), calendar: calendar)
    }

    // MARK: - The basic escalation

    func testNothingBeforeActiveHoursAndAWakeUpWhenTheyStart() {
        let decision = decide(at(7, 30))
        XCTAssertEqual(decision.thirst, .none)
        XCTAssertFalse(decision.shouldNotify)
        XCTAssertEqual(decision.recheckAt, at(9))
    }

    func testNothingDrunkGetsTheIconAfterTheMinimumGapThenOneNotification() {
        XCTAssertEqual(decide(at(9, 44)).thirst, .none)
        XCTAssertEqual(decide(at(9, 44)).recheckAt, at(9, 45))

        let gentle = decide(at(9, 45))
        XCTAssertEqual(gentle.thirst, .gentle)
        XCTAssertFalse(gentle.shouldNotify, "the icon comes first, on its own")
        XCTAssertEqual(gentle.recheckAt, at(9, 55))

        XCTAssertEqual(decide(at(9, 55)).thirst, .building)
        XCTAssertFalse(decide(at(9, 55)).shouldNotify)

        let urgent = decide(at(10, 5))
        XCTAssertEqual(urgent.thirst, .urgent)
        XCTAssertTrue(urgent.shouldNotify)
    }

    // MARK: - Pace

    func testAheadOfPaceIsLeftAloneUntilTheLongGap() {
        // 1 L by 10:00 is four hours ahead of the line, but two hours without a drink is still too
        // long, however good the morning was.
        let quiet = decide(at(11, 59), consumed: 1_000, lastDrink: at(10))
        XCTAssertEqual(quiet.thirst, .none)
        XCTAssertEqual(quiet.recheckAt, at(12))
        XCTAssertEqual(decide(at(12), consumed: 1_000, lastDrink: at(10)).thirst, .gentle)
    }

    func testFallingBehindAfterAheadIsWhenThePaceLineCatchesUp() {
        // 500 ml is where the line is at 11:30. With a long gap that would be later, the line wins.
        var settings = WaterSettings()
        settings.maximumGap = 4 * 3_600
        XCTAssertEqual(decide(at(11, 29), consumed: 500, lastDrink: at(9, 30), settings: settings).thirst, .none)
        XCTAssertEqual(decide(at(11, 30), consumed: 500, lastDrink: at(9, 30), settings: settings).thirst, .gentle)
    }

    func testADrinkResetsTheClockEvenWhenBehind() {
        // Way behind at 14:00, but having just drunk, the next reminder is a minimum gap away —
        // never five minutes after you put the glass down.
        let decision = decide(at(14, 10), consumed: 250, lastDrink: at(14))
        XCTAssertEqual(decision.thirst, .none)
        XCTAssertEqual(decision.recheckAt, at(14, 45))
    }

    func testExpectedFollowsAStraightLineThroughTheActiveHours() {
        let settings = WaterSettings()
        XCTAssertEqual(WaterSchedule.expected(by: at(8), settings: settings, calendar: calendar), 0)
        XCTAssertEqual(WaterSchedule.expected(by: at(14), settings: settings, calendar: calendar), 1_000)
        XCTAssertEqual(WaterSchedule.expected(by: at(18, 59), settings: settings, calendar: calendar), 1_997)
    }

    // MARK: - Done, paused, out of hours

    func testTheGoalMetMeansNothingMoreToday() {
        let decision = decide(at(15), consumed: 2_000, lastDrink: at(10))
        XCTAssertEqual(decision.thirst, .none)
        XCTAssertTrue(decision.goalMet)
        XCTAssertEqual(decision.recheckAt, at(4, day: 8), "look again when the day turns over")
    }

    func testNotTodayIsSilentUntilTheDayTurnsOver() {
        let silenced = decide(at(15), silencedDay: at(4))
        XCTAssertEqual(silenced.thirst, .none)
        XCTAssertEqual(silenced.recheckAt, at(4, day: 8))

        // Yesterday's "not today" means nothing today.
        XCTAssertEqual(decide(at(10, 5, day: 8), silencedDay: at(4)).thirst, .urgent)
    }

    func testNothingAfterActiveHours() {
        XCTAssertEqual(decide(at(20)).thirst, .none)
        XCTAssertFalse(decide(at(20)).shouldNotify)
    }

    func testAReminderThatWouldLandAfterHoursWaitsForTomorrow() {
        let decision = decide(at(18, 40), consumed: 1_900, lastDrink: at(18, 30))
        XCTAssertEqual(decision.thirst, .none)
        XCTAssertEqual(decision.recheckAt, at(9, day: 8))
    }

    func testANotificationIsNeverSentAfterHoursEvenIfTheIconIsDue() {
        // Icon due at 18:45, notification would be 19:05: past the end, so the icon is all you get.
        let decision = decide(at(18, 50), consumed: 1_900, lastDrink: at(18))
        XCTAssertEqual(decision.thirst, .gentle)
        XCTAssertFalse(decide(at(18, 59), consumed: 1_900, lastDrink: at(18)).shouldNotify)
    }

    func testAnEndBeforeTheStartIsNoWindowAtAll() {
        var settings = WaterSettings()
        settings.activeStartMinutes = 18 * 60
        settings.activeEndMinutes = 9 * 60
        XCTAssertEqual(decide(at(12), settings: settings).thirst, .none)
    }

    // MARK: - Quiet times and coming back

    func testSuppressionKeepsTheIconButHoldsTheNotification() {
        let decision = decide(at(10, 5), suppressed: true)
        XCTAssertEqual(decision.thirst, .urgent)
        XCTAssertFalse(decision.shouldNotify)
    }

    func testComingBackGetsAGracePeriodThenExactlyOneReminder() {
        // Away all morning: due since 09:45, notification earned at 10:05. Back at 12:00.
        let inGrace = decide(at(12, 2), graceUntil: at(12, 5))
        XCTAssertFalse(inGrace.shouldNotify)
        XCTAssertEqual(inGrace.recheckAt, at(12, 5))

        let after = decide(at(12, 5), graceUntil: at(12, 5))
        XCTAssertTrue(after.shouldNotify)

        // Once it's sent, the next is a back-off away — not one per slot missed while away.
        let next = decide(at(12, 6), lastNotification: at(12, 5), ignored: 1, graceUntil: at(12, 5))
        XCTAssertFalse(next.shouldNotify)
        XCTAssertEqual(next.thirst, .urgent)
    }

    // MARK: - Back-off and snooze

    func testEachIgnoredNotificationDoublesTheSpacing() {
        // First at 10:05; one ignored → 90 minutes to the next.
        XCTAssertFalse(decide(at(11, 34), lastNotification: at(10, 5), ignored: 1).shouldNotify)
        XCTAssertTrue(decide(at(11, 35), lastNotification: at(10, 5), ignored: 1).shouldNotify)
    }

    func testBackOffIsCappedAtTheMaximumGap() {
        XCTAssertTrue(decide(at(12, 5), lastNotification: at(10, 5), ignored: 6).shouldNotify)
    }

    func testANotificationFromBeforeTheLastDrinkCountsForNothing() {
        // Notified at 10:05, drank at 10:30, behind again. The old notification mustn't push the
        // next one back, whatever the stale ignore count says.
        let decision = decide(at(11, 35), consumed: 250, lastDrink: at(10, 30),
                              lastNotification: at(10, 5), ignored: 3)
        XCTAssertTrue(decision.shouldNotify)
    }

    func testSnoozeIsQuietThenAsksAgainWhenItEnds() {
        let snoozed = decide(at(10, 10), lastNotification: at(10, 5), ignored: 1, snoozedUntil: at(10, 20))
        XCTAssertEqual(snoozed.thirst, .none)
        XCTAssertEqual(snoozed.recheckAt, at(10, 20))

        // At the snooze's end, not the 90-minute back-off's: snooze is a promise of a time.
        let woken = decide(at(10, 20), lastNotification: at(10, 5), ignored: 1, snoozedUntil: at(10, 20))
        XCTAssertTrue(woken.shouldNotify)
    }

    // MARK: - Settings

    func testCompressionScalesEveryDurationAndNothingElse() {
        let compressed = WaterSettings().compressed(by: 60)
        XCTAssertEqual(compressed.minimumGap, 45)
        XCTAssertEqual(compressed.maximumGap, 120)
        XCTAssertEqual(compressed.escalationDelay, 20)
        XCTAssertEqual(compressed.goalMilliliters, 2_000)
        XCTAssertEqual(WaterSettings().compressed(by: 0.5), WaterSettings(), "never stretches")
    }

    func testThirstSymbolsAreAllTemplateFriendlyDrops() {
        XCTAssertEqual(WaterThirst.gentle.symbolName, "drop")
        XCTAssertEqual(WaterThirst.building.symbolName, "drop.halffull")
        XCTAssertEqual(WaterThirst.urgent.symbolName, "drop.fill")
    }
}
