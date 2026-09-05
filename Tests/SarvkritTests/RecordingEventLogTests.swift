import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The log that makes the cursor re-drawable.
///
/// The screen is captured with `showsCursor = false`, so **the only record of where the pointer
/// was is this log**. If the lookup between samples is wrong the cursor lands near but not on the
/// thing it clicked, which reads as a rendering fault rather than an arithmetic one — the exact
/// failure `CaptureGeometry` exists to prevent on the screenshot side.
final class RecordingEventLogTests: XCTestCase {

    private func sample(_ t: TimeInterval, _ x: CGFloat, _ y: CGFloat,
                        kind: CursorKind = .arrow, inside: Bool = true) -> CursorSample {
        CursorSample(t: t, point: CGPoint(x: x, y: y), kind: kind, isInside: inside)
    }

    // MARK: - Position

    func testAPositionIsReadStraightBackAtASampledTime() {
        let log = EventLog(cursor: [sample(0, 10, 10), sample(1, 20, 20)])
        XCTAssertEqual(log.cursorPoint(at: 0)?.x ?? -1, 10, accuracy: 0.0001)
    }

    /// Samples arrive at the display's refresh rate; frames are asked for at arbitrary times.
    func testAPositionBetweenSamplesIsInterpolated() {
        let log = EventLog(cursor: [sample(0, 0, 0), sample(1, 100, 200)])
        let point = log.cursorPoint(at: 0.25)
        XCTAssertEqual(point?.x ?? -1, 25, accuracy: 0.0001)
        XCTAssertEqual(point?.y ?? -1, 50, accuracy: 0.0001)
    }

    func testAPositionBeforeTheFirstSampleHoldsAtTheFirst() {
        let log = EventLog(cursor: [sample(5, 30, 40)])
        XCTAssertEqual(log.cursorPoint(at: 0)?.x ?? -1, 30, accuracy: 0.0001)
    }

    func testAPositionAfterTheLastSampleHoldsAtTheLast() {
        let log = EventLog(cursor: [sample(0, 1, 2), sample(1, 30, 40)])
        XCTAssertEqual(log.cursorPoint(at: 99)?.x ?? -1, 30, accuracy: 0.0001)
    }

    func testAnEmptyLogHasNoPosition() {
        XCTAssertNil(EventLog().cursorPoint(at: 1))
    }

    /// In area and window modes the pointer spends time outside what is being recorded. Drawing it
    /// pinned to the frame edge is worse than not drawing it.
    func testAPositionOutsideTheRecordedRegionIsReportedAsSuch() {
        let log = EventLog(cursor: [sample(0, 10, 10, inside: false)])
        XCTAssertFalse(log.isCursorInside(at: 0))
    }

    func testAPositionInsideTheRecordedRegionIsReportedAsSuch() {
        let log = EventLog(cursor: [sample(0, 10, 10, inside: true)])
        XCTAssertTrue(log.isCursorInside(at: 0))
    }

    // MARK: - Kind

    /// The kind holds until the next sample says otherwise — it is a state, not an event.
    func testTheCursorKindHoldsUntilItChanges() {
        let log = EventLog(cursor: [sample(0, 0, 0, kind: .arrow),
                                    sample(2, 0, 0, kind: .iBeam)])
        XCTAssertEqual(log.cursorKind(at: 1.9), .arrow)
        XCTAssertEqual(log.cursorKind(at: 2.1), .iBeam)
    }

    func testTheCursorKindDefaultsToArrowWithNoSamples() {
        XCTAssertEqual(EventLog().cursorKind(at: 0), .arrow)
    }

    /// An app with its own pointers records the bitmap instead of a kind, so a Photoshop demo does
    /// not show an arrow where the brush was.
    func testACustomCursorCarriesItsBitmapHash() {
        var custom = sample(0, 0, 0, kind: .custom)
        custom.customCursorHash = "abc123"
        XCTAssertEqual(EventLog(cursor: [custom]).customCursorHash(at: 0), "abc123")
    }

    func testAKnownCursorKindCarriesNoBitmapHash() {
        XCTAssertNil(EventLog(cursor: [sample(0, 0, 0)]).customCursorHash(at: 0))
    }

    // MARK: - Ordering

    /// The log is appended from a serial queue but a recovered recording may be truncated
    /// mid-write, so the reader sorts rather than trusting.
    func testSamplesAreSortedOnConstruction() {
        let log = EventLog(cursor: [sample(2, 20, 0), sample(0, 0, 0), sample(1, 10, 0)])
        XCTAssertEqual(log.cursor.map(\.t), [0, 1, 2])
    }

    /// **The synthesised decoder does not call the sorting initialiser.** It assigns the stored
    /// properties directly, so a log read back from disk skips the one line that makes every
    /// lookup in this type safe — and the fixture in the round-trip test above is already in
    /// order, so it cannot catch it. This is that test.
    ///
    /// The JSON is built by re-ordering what the encoder itself produced, rather than written by
    /// hand, so the test says nothing about the wire format and cannot break when it changes.
    func testSamplesAreSortedWhenReadBackFromDisk() throws {
        let ordered = EventLog(cursor: [sample(0, 0, 0), sample(1, 10, 0), sample(2, 20, 0)])
        var asDictionary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(ordered))
                as? [String: Any])
        let cursorEntries = try XCTUnwrap(asDictionary["cursor"] as? [Any])
        asDictionary["cursor"] = Array(cursorEntries.reversed())

        let shuffled = try JSONSerialization.data(withJSONObject: asDictionary)
        let log = try JSONDecoder().decode(EventLog.self, from: shuffled)
        XCTAssertEqual(log.cursor.map(\.t), [0, 1, 2],
                       "a log read back from disk was left in the order the file happened to have")
    }

    func testClicksAreSortedOnConstruction() {
        let log = EventLog(clicks: [ClickEvent(t: 3, point: .zero, button: .left, isDown: true),
                                    ClickEvent(t: 1, point: .zero, button: .left, isDown: true)])
        XCTAssertEqual(log.clicks.map(\.t), [1, 3])
    }

    // MARK: - Truncation

    /// Crash recovery keeps the video up to the last complete fragment, so the sidecars have to be
    /// cut to match or the cursor outlives the picture.
    func testTruncatingDropsEventsPastTheCut() {
        let log = EventLog(cursor: [sample(0, 0, 0), sample(1, 0, 0), sample(5, 0, 0)],
                           clicks: [ClickEvent(t: 4, point: .zero, button: .left, isDown: true)],
                           keys: [KeyEvent(t: 6, label: "A", isModifierCombination: false)])
            .truncated(to: 2)
        XCTAssertEqual(log.cursor.count, 2)
        XCTAssertTrue(log.clicks.isEmpty)
        XCTAssertTrue(log.keys.isEmpty)
    }

    // MARK: - Coding

    func testTheLogSurvivesARoundTrip() throws {
        var custom = sample(1, 5, 6, kind: .custom)
        custom.customCursorHash = "deadbeef"
        let original = EventLog(
            cursor: [sample(0, 1, 2), custom],
            clicks: [ClickEvent(t: 0.5, point: CGPoint(x: 3, y: 4), button: .right, isDown: true)],
            keys: [KeyEvent(t: 0.7, label: "⌘C", isModifierCombination: true)],
            flags: [1.25])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(EventLog.self, from: data), original)
    }
}
