import XCTest
@testable import Sarvkrit

final class CaptureHistoryGroupingTests: XCTestCase {
    /// Built from components rather than an epoch constant, so the fixture says what it means
    /// and does not silently drift with the machine's timezone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1))!
    }

    func testCalendarDaysNotElapsedHours() {
        // A capture from 11pm last night is "Yesterday" at 1am. Calling it "2 hours ago" would be
        // true and useless.
        let lastNight = now.addingTimeInterval(-2 * 3600)
        XCTAssertEqual(CaptureHistoryGrouping.section(for: lastNight, now: now,
                                                      calendar: calendar), .yesterday)
    }

    func testTodayIsToday() {
        XCTAssertEqual(CaptureHistoryGrouping.section(for: now, now: now, calendar: calendar),
                       .today)
        XCTAssertEqual(CaptureHistoryGrouping.section(for: now.addingTimeInterval(-1800),
                                                      now: now, calendar: calendar), .today)
    }

    func testTheWeekAndBeyond() {
        XCTAssertEqual(CaptureHistoryGrouping.section(for: now.addingTimeInterval(-3 * 86400),
                                                      now: now, calendar: calendar),
                       .earlierThisWeek)
        XCTAssertEqual(CaptureHistoryGrouping.section(for: now.addingTimeInterval(-30 * 86400),
                                                      now: now, calendar: calendar), .older)
    }

    func testSectionsComeBackNewestFirstAndSoDoTheirItems() {
        func item(_ daysAgo: Double) -> CaptureHistoryItem {
            CaptureHistoryItem(fileName: "\(daysAgo).png", mode: .area,
                               createdAt: now.addingTimeInterval(-daysAgo * 86400),
                               pixelWidth: 10, pixelHeight: 10, byteCount: 1)
        }
        let grouped = CaptureHistoryGrouping.grouped(
            // Minutes, not hours: `now` is 01:00, so anything even two hours back is
            // already yesterday.
            [item(30), item(0.01), item(3), item(0.02)], now: now, calendar: calendar)

        XCTAssertEqual(grouped.map(\.0), [.today, .earlierThisWeek, .older])
        let today = grouped[0].1
        XCTAssertTrue(today[0].createdAt > today[1].createdAt, "newest first inside a section")
    }

    func testAFutureDateNeverReadsAsInTheFuture() {
        // Clock skew shouldn't caption a capture the user just took as "in 3 hours".
        XCTAssertEqual(CaptureHistoryGrouping.relativeTime(for: now.addingTimeInterval(3 * 3600),
                                                           now: now), "just now")
        XCTAssertEqual(CaptureHistoryGrouping.relativeTime(for: now, now: now), "just now")
    }

    func testEverySectionHasATitle() {
        for section in [CaptureHistoryGrouping.Section.today, .yesterday,
                        .earlierThisWeek, .older] {
            XCTAssertFalse(section.title.isEmpty)
        }
    }
}
