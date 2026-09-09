import XCTest
@testable import Sarvkrit

/// The clicks a finished video shows, which are no longer only the ones that were recorded.
///
/// **Before this, a click could not be edited at all.** `StudioRenderer` read the recording's own
/// `pressDowns` directly, `EventLog.clicks` is `private(set)`, and `ClickEffect` is a stateless
/// namespace of pure functions — there was no per-click object anywhere to add, move or remove. A
/// stray click during a take was in the video for good, and a point you wanted to emphasise but did
/// not happen to click on could not be marked.
///
/// The recording is still never modified. Edits sit beside it, so re-detecting or undoing brings a
/// suppressed click back.
final class ClickTrackTests: XCTestCase {

    private func recorded(_ times: [TimeInterval]) -> [ClickEvent] {
        times.map { ClickEvent(t: $0, point: CGPoint(x: 10, y: 10), button: .left, isDown: true) }
    }

    func testWithNoEditsTheRecordedClicksComeBackUnchanged() {
        let clicks = recorded([1, 2, 3])
        XCTAssertEqual(ClickTrack.effective(recorded: clicks, edits: ClickEdits()), clicks)
    }

    func testAHandPlacedClickAppears() {
        var edits = ClickEdits()
        edits.added = [ManualClick(t: 5, point: CGPoint(x: 40, y: 60))]

        let effective = ClickTrack.effective(recorded: recorded([1]), edits: edits)

        XCTAssertEqual(effective.count, 2)
        let placed = try? XCTUnwrap(effective.last)
        XCTAssertEqual(placed?.t, 5)
        XCTAssertEqual(placed?.point, CGPoint(x: 40, y: 60))
        XCTAssertTrue(placed?.isDown ?? false, "a click effect only fires on a press")
    }

    func testTheResultIsInTimeOrderWhereverEditsLand() {
        var edits = ClickEdits()
        edits.added = [ManualClick(t: 1.5, point: .zero), ManualClick(t: 0.5, point: .zero)]

        let times = ClickTrack.effective(recorded: recorded([1, 2]), edits: edits).map(\.t)

        XCTAssertEqual(times, [0.5, 1, 1.5, 2])
    }

    /// A recorded click can be taken out without touching the recording.
    func testASuppressedRecordedClickDoesNotAppear() {
        var edits = ClickEdits()
        edits.suppressed = [2]

        let times = ClickTrack.effective(recorded: recorded([1, 2, 3]), edits: edits).map(\.t)

        XCTAssertEqual(times, [1, 3])
    }

    /// Suppression matches on time, and a recorded time is a float that has been through JSON —
    /// so it matches within a tolerance rather than exactly, or the click comes back on reload.
    func testSuppressionSurvivesAFloatingPointRoundTrip() {
        var edits = ClickEdits()
        edits.suppressed = [2.0000000001]

        let times = ClickTrack.effective(recorded: recorded([1, 2, 3]), edits: edits).map(\.t)

        XCTAssertEqual(times, [1, 3])
    }

    /// Two clicks a frame apart are different clicks, and suppressing one must not take both.
    func testSuppressionDoesNotTakeANeighbouringClick() {
        var edits = ClickEdits()
        edits.suppressed = [2]

        let times = ClickTrack.effective(recorded: recorded([2, 2.1]), edits: edits).map(\.t)

        XCTAssertEqual(times, [2.1])
    }

    /// Releases are not click effects and must not be invented for hand-placed ones either.
    func testOnlyPressesAreReturned() {
        let mixed = [
            ClickEvent(t: 1, point: .zero, button: .left, isDown: true),
            ClickEvent(t: 1.1, point: .zero, button: .left, isDown: false),
        ]
        XCTAssertEqual(ClickTrack.effective(recorded: mixed, edits: ClickEdits()).map(\.t), [1])
    }
}
