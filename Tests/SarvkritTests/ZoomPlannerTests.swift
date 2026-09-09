import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Deciding where and when to zoom, from the event log alone.
///
/// This is the taste, and taste needs to be adjustable without touching anything that draws — so
/// it is a pure function over clicks and keystrokes with every threshold named in one struct, the
/// same shape `AutoBalance` and `RuleMatcher` already use. No video, no AV types, no main actor.
final class ZoomPlannerTests: XCTestCase {

    private let frame = CGSize(width: 1000, height: 1000)

    private func click(_ t: TimeInterval, _ x: CGFloat, _ y: CGFloat,
                       inside: Bool = true) -> ClickEvent {
        ClickEvent(t: t, point: CGPoint(x: x, y: y), button: .left, isDown: true, isInside: inside)
    }

    private func plan(_ log: EventLog, duration: TimeInterval = 60) -> [ZoomSegment] {
        ZoomPlanner.plan(events: log, frameSize: frame, duration: duration)
    }

    // MARK: - Nothing to do

    func testAnEmptyLogPlansNoZooms() {
        XCTAssertTrue(plan(EventLog()).isEmpty)
    }

    /// A recording of someone reading has clicks nowhere. Inventing zooms for it would be worse
    /// than leaving it alone.
    func testALogWithNoClicksOrKeysPlansNoZooms() {
        let cursor = (0..<50).map {
            CursorSample(t: Double($0) * 0.1, point: CGPoint(x: 500, y: 500))
        }
        XCTAssertTrue(plan(EventLog(cursor: cursor)).isEmpty)
    }

    /// Clicks that landed outside the recorded region aim at nothing, which is what a multi-display
    /// recording produces constantly.
    func testClicksOutsideTheRecordedRegionAreIgnored() {
        XCTAssertTrue(plan(EventLog(clicks: [click(5, 10, 10, inside: false)])).isEmpty)
    }

    // MARK: - Clustering

    func testASingleClickPlansOneZoom() {
        XCTAssertEqual(plan(EventLog(clicks: [click(5, 500, 500)])).count, 1)
    }

    /// Clicking twice on the same button is one action, not two, and zooming out and back in
    /// between them is the single most nauseating thing this feature could do.
    func testTwoClicksCloseInTimeAndSpaceAreOneZoom() {
        let log = EventLog(clicks: [click(5, 500, 500), click(5.4, 540, 520)])
        XCTAssertEqual(plan(log).count, 1)
    }

    func testTwoClicksFarApartInTimeAreTwoZooms() {
        let log = EventLog(clicks: [click(5, 500, 500), click(35, 520, 510)])
        XCTAssertEqual(plan(log).count, 2)
    }

    // MARK: - Level

    /// A single click has no extent, so it gets as close as the planner is allowed to go.
    func testATightActivityZoomsAsFarAsAllowed() {
        let segment = plan(EventLog(clicks: [click(5, 500, 500)])).first
        XCTAssertEqual(segment?.level ?? 0, ZoomPlanner.Tuning().levelRange.upperBound,
                       accuracy: 0.0001)
    }

    /// A drag across most of the screen cannot be zoomed into without hiding half of itself — so
    /// it gets no zoom at all rather than a token one.
    ///
    /// **This used to assert the level clamped to the floor.** That was the implementation
    /// showing through: a 1.2× zoom held over a wide drag is not a close-up, it is a slow drift
    /// the viewer has to follow for nothing. A real recording produced exactly that and it was
    /// the worst thing about the output.
    func testAWideActivityGetsNoZoomAtAll() {
        let clicks = stride(from: CGFloat(100), through: 820, by: 180).enumerated().map {
            click(5 + Double($0.offset) * 0.3, $0.element, 500)
        }
        XCTAssertTrue(plan(EventLog(clicks: clicks)).isEmpty)
    }

    func testEveryPlannedLevelStaysInsideTheAllowedRange() {
        let clicks = (0..<30).map { click(Double($0) * 2, CGFloat($0 * 31 % 1000), 500) }
        let tuning = ZoomPlanner.Tuning()
        for segment in plan(EventLog(clicks: clicks)) {
            XCTAssertTrue(tuning.levelRange.contains(segment.level), "\(segment.level)")
        }
    }

    // MARK: - Anchor

    /// Following a pointer that barely moves reads as drift, so a still activity is pinned.
    func testAStillActivityIsAnchoredInPlace() {
        guard case .fixed = plan(EventLog(clicks: [click(5, 500, 500)])).first?.anchor else {
            return XCTFail("a single click should be anchored, not followed")
        }
    }

    /// Moves enough to be worth following — a quarter of the frame — but stays tight enough to
    /// earn a real zoom. Anything wider than that now produces no segment to have an anchor.
    func testAMovingActivityFollowsTheCursor() {
        let clicks = stride(from: CGFloat(300), through: 540, by: 80).enumerated().map {
            click(5 + Double($0.offset) * 0.3, $0.element, 500)
        }
        guard case .followCursor = plan(EventLog(clicks: clicks)).first?.anchor else {
            return XCTFail("a moving activity should follow the cursor")
        }
    }

    /// Anchors are normalised so they survive a change of export resolution.
    func testAFixedAnchorIsNormalisedToTheFrame() {
        guard case .fixed(let point) = plan(EventLog(clicks: [click(5, 250, 750)])).first?.anchor
        else { return XCTFail("expected a fixed anchor") }
        XCTAssertEqual(point.x, 0.25, accuracy: 0.01)
        XCTAssertEqual(point.y, 0.75, accuracy: 0.01)
    }

    // MARK: - Structure

    func testSegmentsComeBackSortedByStart() {
        let clicks = [click(30, 100, 100), click(5, 500, 500), click(50, 900, 900)]
        let starts = plan(EventLog(clicks: clicks)).map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    /// Overlapping segments have no defined transform, so the renderer would pick one arbitrarily
    /// and the zoom would flicker between them.
    func testSegmentsNeverOverlap() {
        let clicks = (0..<40).map { click(Double($0) * 0.7, CGFloat($0 * 47 % 1000), 500) }
        let segments = plan(EventLog(clicks: clicks))
        for (a, b) in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "segments overlap")
        }
    }

    func testSegmentsStayInsideTheRecording() {
        let clicks = [click(0.05, 500, 500), click(29.9, 500, 500)]
        for segment in plan(EventLog(clicks: clicks), duration: 30) {
            XCTAssertGreaterThanOrEqual(segment.start, 0)
            XCTAssertLessThanOrEqual(segment.end, 30)
        }
    }

    /// `isAutomatic` is what lets "Re-detect zooms" replace generated segments while leaving
    /// hand-made ones alone. Without it the button cannot be pressed twice without losing work.
    func testEveryPlannedSegmentIsMarkedAutomatic() {
        let clicks = (0..<10).map { click(Double($0) * 4, 500, 500) }
        XCTAssertTrue(plan(EventLog(clicks: clicks)).allSatisfy(\.isAutomatic))
    }

    /// A zoom shorter than the eye takes to arrive is worse than no zoom. This is the rule that
    /// stops a click-heavy demo feeling frantic.
    func testNoPlannedSegmentIsShorterThanTheMinimum() {
        let clicks = (0..<20).map { click(Double($0) * 1.1, CGFloat($0 * 91 % 1000), 500) }
        let tuning = ZoomPlanner.Tuning()
        for segment in plan(EventLog(clicks: clicks)) {
            XCTAssertGreaterThanOrEqual(segment.end - segment.start, tuning.minimumActivity)
        }
    }

    /// A click storm must not become a zoom storm.
    func testAClickStormIsCappedInDensity() {
        let clicks = (0..<60).map { click(Double($0) * 0.5, CGFloat($0 * 37 % 1000), 500) }
        let segments = plan(EventLog(clicks: clicks), duration: 30)
        XCTAssertLessThanOrEqual(segments.count, Int(30 / ZoomPlanner.Tuning().minimumSpacing) + 1)
    }

    // MARK: - Typing

    /// The most common thing in a software demo is filling something in, and it produces no clicks
    /// at all. A planner that only watches the mouse ignores it entirely.
    func testATypingBurstPlansAZoom() {
        let keys = (0..<8).map {
            KeyEvent(t: 10 + Double($0) * 0.15, label: "A", isModifierCombination: false)
        }
        let cursor = [CursorSample(t: 10, point: CGPoint(x: 400, y: 400))]
        XCTAssertEqual(plan(EventLog(cursor: cursor, keys: keys)).count, 1)
    }

    func testAStrayKeypressDoesNotPlanAZoom() {
        let keys = [KeyEvent(t: 10, label: "A", isModifierCombination: false)]
        XCTAssertTrue(plan(EventLog(keys: keys)).isEmpty)
    }

    // MARK: - Zooms that would be worse than nothing

    /// **From a real recording.** Twenty-eight clicks spread across a twelve-second demo produced
    /// one eleven-second segment at 1.2× — the floor — because every activity touched its
    /// neighbour and the merged bounding box covered most of the screen. A zoom that barely zooms,
    /// held for the whole video, is visual noise: it is not a close-up, it is a slow drift.
    func testClicksAllOverTheScreenPlanNoZoomRatherThanOneUselessOne() {
        let scattered = (0..<28).map { index -> ClickEvent in
            let t: TimeInterval = 0.2 + Double(index) * 0.42
            let x: CGFloat = CGFloat(80 + (index * 137) % 840)
            let y: CGFloat = CGFloat(60 + (index * 211) % 880)
            return click(t, x, y)
        }
        let planned = plan(EventLog(clicks: scattered), duration: 12.4)
        for segment in planned {
            XCTAssertGreaterThan(segment.level, ZoomPlanner.Tuning().levelRange.lowerBound + 0.01,
                                 "a zoom was planned that barely zooms")
        }
    }

    /// One segment covering nearly the whole recording is not a zoom, it is a crop — and it is
    /// what the merge rules produced before they were capped.
    func testNoSegmentSwallowsTheWholeRecording() {
        let busy = (0..<28).map { index -> ClickEvent in
            let t: TimeInterval = 0.2 + Double(index) * 0.42
            let x: CGFloat = CGFloat(80 + (index * 137) % 840)
            return click(t, x, 500)
        }
        for segment in plan(EventLog(clicks: busy), duration: 12.4) {
            XCTAssertLessThan(segment.duration, 12.4 * 0.8,
                              "one segment covered almost the entire recording")
        }
    }

    /// Activity that genuinely continues should still be capped, so a five-minute demo of steady
    /// clicking does not become one five-minute zoom.
    func testAContinuousStreamOfClicksIsBrokenIntoSeveralZooms() {
        let steady = (0..<80).map { index -> ClickEvent in
            let t: TimeInterval = 1 + Double(index) * 0.5
            let x: CGFloat = 500 + CGFloat((index % 3) * 20)
            return click(t, x, 500)
        }
        let planned = plan(EventLog(clicks: steady), duration: 45)
        XCTAssertGreaterThan(planned.count, 1, "continuous clicking became one endless zoom")
        for segment in planned {
            XCTAssertLessThanOrEqual(segment.duration,
                                     ZoomPlanner.Tuning().maximumActivity + 0.01)
        }
    }

    /// The case that must keep working: a tight cluster still earns a real close-up.
    /// Asserted against the top of the range rather than against a number.
    ///
    /// **It used to say `> 2`, which stopped being true when the ceiling came down to 2.0** — and
    /// the ceiling coming down was the point of that change, not a regression. What "properly"
    /// means here is "as close as the planner is allowed to go", so that is what it now says.
    func testATightClusterStillZoomsProperly() {
        let tight = (0..<4).map { click(5 + Double($0) * 0.3, 500, 500) }
        let segment = plan(EventLog(clicks: tight)).first
        XCTAssertEqual(segment?.level ?? 0, ZoomPlanner.Tuning().levelRange.upperBound,
                       accuracy: 0.001)
    }
}
