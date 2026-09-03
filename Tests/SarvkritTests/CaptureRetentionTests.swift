import XCTest
@testable import Sarvkrit

/// Retention, as a table. The alternative to testing this is finding out a month later that
/// someone's screenshots went early — or never went at all.
final class CaptureRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func item(_ id: UUID = UUID(), daysAgo: Double) -> (id: UUID, createdAt: Date) {
        (id: id, createdAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    func testForeverKeepsEverything() {
        let items = [item(daysAgo: 0), item(daysAgo: 400), item(daysAgo: 10_000)]
        XCTAssertTrue(CaptureRetention.expired(items: items, now: now, window: .forever).isEmpty)
    }

    func testAMonthDropsOlderAndKeepsNewer() {
        let old = UUID(), fresh = UUID()
        let expired = CaptureRetention.expired(
            items: [item(old, daysAgo: 31), item(fresh, daysAgo: 29)],
            now: now, window: .month)
        XCTAssertEqual(expired, [old])
    }

    func testAnItemExactlyOnTheBoundaryIsKept() {
        // Deleting on the tick is an off-by-one the user experiences as "it said a month and it
        // was gone in a month". Keeping is the forgiving direction.
        let edge = UUID()
        let expired = CaptureRetention.expired(
            items: [item(edge, daysAgo: 30)], now: now, window: .month)
        XCTAssertTrue(expired.isEmpty)
    }

    func testAnItemDatedInTheFutureIsNeverDeleted() {
        // Clock skew and timezone changes both produce this. Deleting someone's newest screenshot
        // because their clock jumped is far worse than keeping one too long.
        let future = UUID()
        let expired = CaptureRetention.expired(
            items: [item(future, daysAgo: -5)], now: now, window: .week)
        XCTAssertTrue(expired.isEmpty)
    }

    func testAWeekIsShorterThanAMonth() {
        let mid = UUID()
        let items = [item(mid, daysAgo: 14)]
        XCTAssertEqual(CaptureRetention.expired(items: items, now: now, window: .week), [mid])
        XCTAssertTrue(CaptureRetention.expired(items: items, now: now, window: .month).isEmpty)
    }

    func testEmptyInputIsFine() {
        XCTAssertTrue(CaptureRetention.expired(items: [], now: now, window: .month).isEmpty)
    }

    func testEveryWindowHasATitle() {
        for window in CaptureRetention.Window.allCases {
            XCTAssertFalse(window.title.isEmpty)
        }
    }
}
