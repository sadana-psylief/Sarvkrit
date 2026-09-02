import XCTest
@testable import Sarvkrit

/// The case these cover is the reason the type exists: a rewritten keyDown whose keyUp never
/// arrives must not rewrite some later, unrelated press of the same key.
final class PendingRewritesTests: XCTestCase {

    func testKeyUpRightAfterItsKeyDownIsRewritten() {
        var pending = PendingRewrites()
        pending.record(CutPasteRewriter.keyX, now: 100)
        XCTAssertTrue(pending.consume(CutPasteRewriter.keyX, now: 100.08))
    }

    func testKeyUpWithNoRecordedKeyDownIsLeftAlone() {
        var pending = PendingRewrites()
        XCTAssertFalse(pending.consume(CutPasteRewriter.keyX, now: 100))
    }

    /// The bug. A ⌘X keyDown is rewritten, the user switches apps so its keyUp goes elsewhere, and
    /// much later they press x in a text editor. That keyUp must arrive as an x.
    func testStrandedKeyDownDoesNotRewriteAMuchLaterKeyUp() {
        var pending = PendingRewrites()
        pending.record(CutPasteRewriter.keyX, now: 100)
        XCTAssertFalse(
            pending.consume(CutPasteRewriter.keyX, now: 100 + PendingRewrites.window + 0.01),
            "a keycode stranded beyond the window must not rewrite an unrelated keyUp")
    }

    /// Whether it was honoured or not, the record is gone — otherwise an expired entry would sit
    /// there being reconsidered on every subsequent keyUp.
    func testExpiredRecordIsConsumedRatherThanReconsidered() {
        var pending = PendingRewrites()
        pending.record(CutPasteRewriter.keyX, now: 100)
        _ = pending.consume(CutPasteRewriter.keyX, now: 200)
        XCTAssertTrue(pending.isEmpty)
    }

    func testOneKeyUpConsumesOnlyItsOwnRecord() {
        var pending = PendingRewrites()
        pending.record(CutPasteRewriter.keyX, now: 100)
        pending.record(CutPasteRewriter.keyV, now: 100)

        XCTAssertTrue(pending.consume(CutPasteRewriter.keyX, now: 100.05))
        XCTAssertTrue(pending.consume(CutPasteRewriter.keyV, now: 100.05),
                      "consuming X must not discard the pending V")
    }

    func testTheSameKeyPressedTwiceIsRewrittenBothTimes() {
        var pending = PendingRewrites()
        pending.record(CutPasteRewriter.keyX, now: 100)
        XCTAssertTrue(pending.consume(CutPasteRewriter.keyX, now: 100.05))
        pending.record(CutPasteRewriter.keyX, now: 101)
        XCTAssertTrue(pending.consume(CutPasteRewriter.keyX, now: 101.05))
    }

    /// A session that strands entries repeatedly must not grow a record per key forever.
    func testStaleRecordsAreSweptRatherThanAccumulating() {
        var pending = PendingRewrites()
        for i in 0..<50 {
            pending.record(Int64(i), now: 100 + Double(i))
        }
        // Everything older than the window is gone, so the earliest keycodes no longer match.
        XCTAssertFalse(pending.consume(0, now: 200))
        XCTAssertFalse(pending.consume(10, now: 200))
    }
}
