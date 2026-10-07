import XCTest
@testable import Sarvkrit

final class HydrationLogTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 7, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - The day boundary

    func testTheDayTurnsOverAtTheDayStartNotMidnight() {
        XCTAssertEqual(HydrationDay.start(of: at(2, day: 8), dayStartHour: 4, calendar: calendar), at(4))
        XCTAssertEqual(HydrationDay.start(of: at(5, day: 8), dayStartHour: 4, calendar: calendar), at(4, day: 8))
        XCTAssertEqual(HydrationDay.end(of: at(23), dayStartHour: 4, calendar: calendar), at(4, day: 8))
    }

    func testALateNightDrinkCountsTowardTheDayBefore() {
        var log = HydrationLog()
        log.add(milliliters: 250, at: at(22))
        log.add(milliliters: 250, at: at(0, 30, day: 8))
        log.add(milliliters: 500, at: at(9, day: 8))

        XCTAssertEqual(log.total(onDayOf: at(23), dayStartHour: 4, calendar: calendar), 500)
        XCTAssertEqual(log.total(onDayOf: at(12, day: 8), dayStartHour: 4, calendar: calendar), 500)
        // With a midnight boundary, the 00:30 glass moves.
        XCTAssertEqual(log.total(onDayOf: at(12, day: 8), dayStartHour: 0, calendar: calendar), 750)
    }

    func testEntriesForADayAreInTimeOrder() {
        var log = HydrationLog()
        log.add(milliliters: 250, at: at(14))
        log.add(milliliters: 500, at: at(10))
        let day = log.entries(onDayOf: at(12), dayStartHour: 4, calendar: calendar)
        XCTAssertEqual(day.map(\.milliliters), [500, 250])
    }

    // MARK: - Undo and remove

    func testUndoRemovesTheLastThingLoggedEvenIfItWasBackdated() {
        var log = HydrationLog()
        log.add(milliliters: 250, at: at(14))
        log.add(milliliters: 500, at: at(10)) // "I had one this morning"

        XCTAssertEqual(log.lastDrink, at(14), "the latest drink is the latest by time")
        XCTAssertEqual(log.undoLast()?.milliliters, 500, "but undo means the last tap")
        XCTAssertEqual(log.entries.map(\.milliliters), [250])
    }

    func testUndoOnAnEmptyLogDoesNothing() {
        var log = HydrationLog()
        XCTAssertNil(log.undoLast())
    }

    func testRemoveTakesOutOneEntryById() {
        var log = HydrationLog()
        let keep = log.add(milliliters: 250, at: at(10))
        let drop = log.add(milliliters: 250, at: at(11))
        log.remove(id: drop.id)
        XCTAssertEqual(log.entries, [keep])
    }

    // MARK: - History and retention

    func testDailyTotalsIncludeEmptyDaysOldestFirst() {
        var log = HydrationLog()
        log.add(milliliters: 1_000, at: at(10, day: 5))
        log.add(milliliters: 750, at: at(10, day: 7))

        let totals = log.dailyTotals(days: 3, endingAt: at(12), dayStartHour: 4, calendar: calendar)
        XCTAssertEqual(totals.map(\.milliliters), [1_000, 0, 750])
        XCTAssertEqual(totals.map(\.day), [at(4, day: 5), at(4, day: 6), at(4, day: 7)])
    }

    func testPruneDropsOnlyWhatIsPastTheRetentionWindow() {
        var log = HydrationLog()
        log.add(milliliters: 250, at: at(10, day: 1, month: 6))
        log.add(milliliters: 250, at: at(10, day: 1, month: 9))
        XCTAssertTrue(log.prune(now: at(12), calendar: calendar))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertFalse(log.prune(now: at(12), calendar: calendar), "nothing left to prune")
    }

    func testTheLogRoundTripsThroughCodable() throws {
        var log = HydrationLog()
        log.add(milliliters: 250, at: at(10))
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(HydrationLog.self, from: data), log)
    }

    // MARK: - Units

    func testMillilitresReadAsLitresFromOneLitreUp() {
        XCTAssertEqual(VolumeUnit.milliliters.format(250), "250 ml")
        XCTAssertTrue(VolumeUnit.milliliters.format(2_000).hasSuffix(" L"))
        XCTAssertTrue(VolumeUnit.milliliters.format(1_500).hasPrefix("1"))
    }

    func testOuncesConvertBothWays() {
        XCTAssertEqual(VolumeUnit.fluidOunces.format(237), "8 fl oz")
        XCTAssertEqual(VolumeUnit.fluidOunces.milliliters(from: 8), 237)
        XCTAssertEqual(VolumeUnit.fluidOunces.value(of: 1_000), 33.81, accuracy: 0.01)
        XCTAssertEqual(VolumeUnit.milliliters.milliliters(from: 250), 250)
    }
}
