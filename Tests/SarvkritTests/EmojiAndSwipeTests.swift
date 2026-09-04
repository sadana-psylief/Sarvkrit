import XCTest
@testable import Sarvkrit

final class EmojiCatalogueTests: XCTestCase {

    func testEveryEmojiAppearsOnceAcrossTheWholeCatalogue() {
        // A duplicate is invisible in the grid and confusing in "recent", where the same mark
        // would then be selectable from two places with only one highlighted.
        XCTAssertEqual(Set(EmojiCatalogue.all).count, EmojiCatalogue.all.count)
        XCTAssertEqual(Set(EmojiCatalogue.groups.map(\.id)).count, EmojiCatalogue.groups.count)
        XCTAssertTrue(EmojiCatalogue.all.contains(EmojiCatalogue.default),
                      "the default must be pickable, or it can never be got back")
    }

    func testTheGridIsFullRows() {
        // Six across. A group of eleven leaves a hole that reads as a missing emoji.
        for group in EmojiCatalogue.groups {
            XCTAssertEqual(group.emoji.count % 6, 0, "\(group.title) leaves a ragged row")
        }
    }

    func testUsingAnEmojiMovesItToTheFrontWithoutDuplicatingIt() {
        var recents = EmojiCatalogue.recents([], adding: "✅")
        recents = EmojiCatalogue.recents(recents, adding: "🔥")
        recents = EmojiCatalogue.recents(recents, adding: "✅")
        XCTAssertEqual(recents, ["✅", "🔥"])
    }

    func testRecentsStopAtOneRow() {
        var recents: [String] = []
        for emoji in EmojiCatalogue.all {
            recents = EmojiCatalogue.recents(recents, adding: emoji)
        }
        XCTAssertEqual(recents.count, EmojiCatalogue.recentLimit)
        XCTAssertEqual(recents.first, EmojiCatalogue.all.last, "newest first")
    }

    @MainActor
    func testRecentsSurviveARelaunch() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "EmojiRecentsTests"))
        suite.removePersistentDomain(forName: "EmojiRecentsTests")
        defer { suite.removePersistentDomain(forName: "EmojiRecentsTests") }

        EmojiRecents(defaults: suite).record("🚀")
        XCTAssertEqual(EmojiRecents(defaults: suite).emoji, ["🚀"])
    }
}

/// Telling a dismissing flick apart from a drag into another app.
///
/// The asymmetry is the whole design and is worth restating: a missed swipe leaves a thumbnail on
/// screen for another second, and a missed drag loses a file somebody was dropping into a message.
/// So every ambiguous case has to come back `.dragOut`.
final class QuickAccessSwipeTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    /// Parked at the bottom-right, which is the default corner.
    private let panel = CGRect(x: 1700, y: 40, width: 180, height: 130)

    private func decide(dx: CGFloat, dy: CGFloat,
                        panel: CGRect? = nil) -> QuickAccessSwipe.Decision {
        let start = CGPoint(x: 1780, y: 100)
        return QuickAccessSwipe.decide(from: start,
                                       to: CGPoint(x: start.x + dx, y: start.y + dy),
                                       panel: panel ?? self.panel, screen: screen)
    }

    func testATinyMovementDecidesNothingYet() {
        XCTAssertEqual(decide(dx: 4, dy: 0), .undecided)
        XCTAssertEqual(decide(dx: 0, dy: -6), .undecided)
    }

    func testFlickingOutPastTheNearEdgeDismisses() {
        XCTAssertEqual(decide(dx: 60, dy: 0), .dismiss)
        XCTAssertEqual(decide(dx: 40, dy: 10), .dismiss, "a hand drifts; 2:1 still counts")
    }

    func testFlickingInwardIsADragNotADismiss() {
        // Left, from the right-hand corner, is where every other app is.
        XCTAssertEqual(decide(dx: -60, dy: 0), .dragOut)
    }

    func testAnOverlayParkedOnTheLeftDismissesLeftwards() {
        let left = CGRect(x: 40, y: 40, width: 180, height: 130)
        XCTAssertEqual(decide(dx: -60, dy: 0, panel: left), .dismiss)
        XCTAssertEqual(decide(dx: 60, dy: 0, panel: left), .dragOut)
    }

    func testDraggingUpOrDownIsAlwaysADrag() {
        for dy in [CGFloat(-80), 80] {
            XCTAssertEqual(decide(dx: 0, dy: dy), .dragOut)
            XCTAssertEqual(decide(dx: 30, dy: dy), .dragOut, "a diagonal is a drag")
        }
    }

    func testTheDiagonalBoundarySitsWhereTheRatioSaysAndFavoursTheDrag() {
        // Exactly 2:1 is a swipe; a hair less is a drag. Stated as a test because the inequality
        // is the only thing standing between a flick and a lost file.
        XCTAssertEqual(decide(dx: 40, dy: 20), .dismiss)
        XCTAssertEqual(decide(dx: 40, dy: 21), .dragOut)
    }
}
