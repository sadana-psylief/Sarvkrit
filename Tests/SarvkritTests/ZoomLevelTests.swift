import CoreGraphics
import XCTest
@testable import Sarvkrit

/// How close the automatic zoom decides to go.
///
/// **"It only focuses on the cursor, it does not take into account where the cursor is."** Both
/// halves were true and for a reason worth writing down. The level *was* derived from the
/// activity's extent — zoom until it fills `targetCoverage` of the frame — but the extent was the
/// bounding box of **click points only**, and a single click has no extent at all. Guarded by
/// `max(box.width, 1)`, the arithmetic asked for a 600× zoom and took the ceiling. Typing was the
/// same: a typing run carried exactly one cursor sample. So every isolated click and every typing
/// burst landed on 2.5×, and a real recording read `2.50, 2.50, 2.50, 1.69, 1.38`.
///
/// The cursor was the one signal the planner never used. It does now — but only where the pointer
/// *rested*, not where it travelled. Where somebody moved the mouse from is not what they are
/// showing you.
final class ZoomLevelTests: XCTestCase {

    private let frame = CGSize(width: 1000, height: 1000)

    private func click(_ t: TimeInterval, _ x: CGFloat, _ y: CGFloat) -> ClickEvent {
        ClickEvent(t: t, point: CGPoint(x: x, y: y), button: .left, isDown: true, isInside: true)
    }

    /// A cursor track from `from` to `to` across `over` seconds, sampled at 20 Hz. The speed is
    /// what decides whether these points count, so it is the parameter that matters.
    private func track(from: CGPoint, to: CGPoint,
                       start: TimeInterval, over: TimeInterval) -> [CursorSample] {
        let steps = max(1, Int(over * 20))
        return (0...steps).map { step in
            let fraction = CGFloat(step) / CGFloat(steps)
            return CursorSample(t: start + over * Double(step) / Double(steps),
                                point: CGPoint(x: from.x + (to.x - from.x) * fraction,
                                               y: from.y + (to.y - from.y) * fraction),
                                kind: .arrow)
        }
    }

    private func parked(at point: CGPoint, from: TimeInterval,
                        over: TimeInterval) -> [CursorSample] {
        track(from: point, to: point, start: from, over: over)
    }

    /// The recorder sets `isInside: false` whenever the pointer leaves the recorded region, which
    /// happens constantly in area and window modes.
    private func outside(_ samples: [CursorSample]) -> [CursorSample] {
        samples.map {
            CursorSample(t: $0.t, point: $0.point, kind: $0.kind, isInside: false)
        }
    }

    private func level(_ log: EventLog) -> Double? {
        ZoomPlanner.plan(events: log, frameSize: frame, duration: 60).first?.level
    }

    // MARK: - The pointer's own extent counts

    /// A click with the pointer parked on it is a tight target, and still gets the closest zoom.
    func testAClickWithTheCursorParkedOnItZoomsAllTheWay() {
        let log = EventLog(cursor: parked(at: CGPoint(x: 500, y: 500), from: 3, over: 4),
                           clicks: [click(5, 500, 500)])
        XCTAssertEqual(level(log) ?? 0, ZoomPlanner.Tuning().levelRange.upperBound,
                       accuracy: 0.001)
    }

    /// **The assertion that fails today.** The same click, but the pointer spent the surrounding
    /// couple of seconds working slowly across a region — so the region is the subject, not the
    /// click, and zooming to 2.5× would crop most of what was being shown.
    func testAPointerWorkingAcrossARegionZoomsLessThanAClickAlone() {
        let working = EventLog(
            cursor: track(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 700, y: 500),
                          start: 3.8, over: 2),
            clicks: [click(5, 500, 500)])
        let still = EventLog(cursor: parked(at: CGPoint(x: 500, y: 500), from: 3, over: 4),
                             clicks: [click(5, 500, 500)])

        let spread = try? XCTUnwrap(level(working))
        let tight = try? XCTUnwrap(level(still))
        XCTAssertNotNil(spread)
        XCTAssertLessThan(spread ?? 9, (tight ?? 0) - 0.2,
                          "the pointer's own extent did not change the level")
    }

    /// And it lands where the arithmetic says: a 400pt-wide region in a 1000pt frame at 60%
    /// coverage is 1.5×.
    func testTheLevelFollowsTheRegionTheCursorCovered() {
        let log = EventLog(
            cursor: track(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 700, y: 500),
                          start: 3.8, over: 2),
            clicks: [click(5, 500, 500)])
        XCTAssertEqual(level(log) ?? 0, 1.5, accuracy: 0.15)
    }

    // MARK: - Travelling is not attending

    /// **Where somebody moved the mouse from is not what they are showing you.** A fling across
    /// the screen to reach a button says nothing about the subject, and counting it would drag the
    /// box out to the full width and cancel the zoom on almost every click.
    func testAFastSweepToTheTargetIsIgnored() {
        let flung = EventLog(
            cursor: track(from: CGPoint(x: 60, y: 500), to: CGPoint(x: 940, y: 500),
                          start: 4.6, over: 0.25)
                + parked(at: CGPoint(x: 940, y: 500), from: 4.85, over: 1),
            clicks: [click(5, 940, 500)])

        XCTAssertEqual(level(flung) ?? 0, ZoomPlanner.Tuning().levelRange.upperBound,
                       accuracy: 0.001,
                       "a fast sweep was counted as part of the subject")
    }

    /// The distinction is speed and nothing else, so the same two endpoints crossed slowly do
    /// count. Without this the test above would pass by ignoring the cursor entirely.
    func testTheSameTravelDoneSlowlyDoesCount() {
        let slow = EventLog(
            cursor: track(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 700, y: 500),
                          start: 3.8, over: 2),
            clicks: [click(5, 500, 500)])
        let fast = EventLog(
            cursor: track(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 700, y: 500),
                          start: 4.9, over: 0.15)
                + parked(at: CGPoint(x: 700, y: 500), from: 5.05, over: 1),
            clicks: [click(5, 500, 500)])

        XCTAssertLessThan(level(slow) ?? 9, level(fast) ?? 0)
    }

    /// A pointer outside the recorded region is not evidence about anything on screen — the same
    /// rule the click path already applies with its own `isInside` flag.
    func testCursorSamplesOutsideTheRecordingAreIgnored() {
        let log = EventLog(
            cursor: outside(parked(at: CGPoint(x: -400, y: 500), from: 3.8, over: 2))
                + parked(at: CGPoint(x: 500, y: 500), from: 4.9, over: 0.2),
            clicks: [click(5, 500, 500)])
        XCTAssertEqual(level(log) ?? 0, ZoomPlanner.Tuning().levelRange.upperBound,
                       accuracy: 0.001)
    }

    // MARK: - Typing gets the same treatment

    /// A typing run used to carry exactly one cursor sample, so it always landed on the ceiling
    /// regardless of what the pointer was doing around it.
    func testATypingRunReadsTheCursorTooRatherThanOneSample() {
        let keys = (0..<8).map {
            KeyEvent(t: 5 + Double($0) * 0.2, label: "a", isModifierCombination: false)
        }
        // A 400pt spread: wide enough that the coverage rule asks for 1.5× rather than the
        // ceiling, and narrow enough that it is not floored back up to still-a-zoom. Both bounds
        // matter, and a spread outside them would make this test pass or fail for the wrong reason.
        let spread = EventLog(
            cursor: track(from: CGPoint(x: 300, y: 500), to: CGPoint(x: 700, y: 500),
                          start: 4, over: 3),
            keys: keys)
        let still = EventLog(cursor: parked(at: CGPoint(x: 500, y: 500), from: 4, over: 3),
                             keys: keys)

        XCTAssertLessThan(level(spread) ?? 9, (level(still) ?? 0) - 0.2)
    }

    // MARK: - Nothing regressed

    /// With no cursor track at all the planner falls back to the clicks, which is what every
    /// existing planner test relies on and what a log from a build that recorded no cursor has.
    func testWithNoCursorTrackTheClicksStillDecide() {
        XCTAssertEqual(level(EventLog(clicks: [click(5, 500, 500)])) ?? 0,
                       ZoomPlanner.Tuning().levelRange.upperBound, accuracy: 0.001)
    }

    func testEveryLevelStaysInsideTheAllowedRange() {
        let clicks = (0..<20).map { click(Double($0) * 2, CGFloat($0 * 47 % 1000), 500) }
        let cursor: [CursorSample] = (0..<400).map { step in
            let x = CGFloat((step * 13) % 1000)
            let y = CGFloat((step * 7) % 1000)
            return CursorSample(t: Double(step) * 0.1, point: CGPoint(x: x, y: y), kind: .arrow)
        }
        let tuning = ZoomPlanner.Tuning()
        for segment in ZoomPlanner.plan(events: EventLog(cursor: cursor, clicks: clicks),
                                        frameSize: frame, duration: 60) {
            XCTAssertTrue(tuning.levelRange.contains(segment.level), "\(segment.level)")
        }
    }
}
