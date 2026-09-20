import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Turning a sampled pointer path into one that looks like it has weight.
///
/// **The tension this suite exists to hold.** Smoothing removes the hand jitter that is invisible
/// at 1× and obvious at 2.5× — but smoothing is lag, and a cursor that arrives after the click it
/// made is far worse than a jittery one. So the smoother is suspended around clicks, and
/// `testTheCursorIsExactlyOnTheClickPoint` is the test that matters most in the file.
final class CursorPathTests: XCTestCase {

    private func straightPath(count: Int = 60) -> [CursorSample] {
        (0..<count).map {
            CursorSample(t: Double($0) / 60, point: CGPoint(x: Double($0) * 10, y: 500))
        }
    }

    /// A straight line with alternating noise on it — what a real hand produces.
    private func jitteryPath(count: Int = 60) -> [CursorSample] {
        (0..<count).map { index -> CursorSample in
            let wobble: Double = index % 2 == 0 ? 6 : -6
            let x: Double = Double(index) * 10 + wobble
            return CursorSample(t: Double(index) / 60, point: CGPoint(x: x, y: 500))
        }
    }

    /// Sum of second differences: how much the path changes direction. Lower is smoother.
    ///
    /// **Measured over the interior only.** Any symmetric filter has to invent something at the
    /// ends of the array, and every choice about that shows up as curvature in the first and last
    /// few samples. That is a question about boundary handling, not about the filter, and letting
    /// it into the measurement makes these assertions fragile for a reason unrelated to what they
    /// are checking.
    private func wobble(_ samples: [CursorSample], margin: Int = 6) -> Double {
        let usable = samples.dropFirst(margin).dropLast(margin)
        guard usable.count > 2 else { return 0 }
        let points = usable.map(\.point)
        var total = 0.0
        for index in 2..<points.count {
            let a = points[index - 2], b = points[index - 1], c = points[index]
            let dx = c.x - 2 * b.x + a.x
            let dy = c.y - 2 * b.y + a.y
            total += Double(hypot(dx, dy))
        }
        return total
    }

    // MARK: - Smoothing

    /// Off means the raw path, not "a bit less". Some recordings — drawing apps, precise dragging
    /// — are made worse by any smoothing at all, and the setting has to mean what it says.
    func testSmoothingOffReturnsThePathUntouched() {
        let path = jitteryPath()
        XCTAssertEqual(CursorPath.smoothed(path, smoothing: .off), path)
    }

    func testSmoothingReducesWobble() {
        let raw = jitteryPath()
        let smoothed = CursorPath.smoothed(raw, smoothing: .standard)
        XCTAssertLessThan(wobble(smoothed), wobble(raw) * 0.6)
    }

    func testHeavierSmoothingWobblesLess() {
        let raw = jitteryPath()
        XCTAssertLessThan(wobble(CursorPath.smoothed(raw, smoothing: .heavy)),
                          wobble(CursorPath.smoothed(raw, smoothing: .light)))
    }

    func testSmoothingKeepsEverySample() {
        let raw = jitteryPath()
        XCTAssertEqual(CursorPath.smoothed(raw, smoothing: .heavy).count, raw.count)
    }

    func testSmoothingPreservesTheTimestamps() {
        let raw = jitteryPath()
        XCTAssertEqual(CursorPath.smoothed(raw, smoothing: .heavy).map(\.t), raw.map(\.t))
    }

    /// A straight path has nothing to smooth, so it should come back essentially unchanged rather
    /// than being dragged behind by the filter.
    func testSmoothingDoesNotDragAStraightPathOffCourse() {
        let raw = straightPath()
        let smoothed = CursorPath.smoothed(raw, smoothing: .standard)
        let drift = zip(raw, smoothed).map { hypot($0.point.x - $1.point.x, $0.point.y - $1.point.y) }
        XCTAssertLessThan(drift.max() ?? 999, 12)
    }

    // MARK: - Clicks

    /// **The one that matters.** A click that lands somewhere the cursor visibly is not looks like
    /// the app mis-clicked, and no amount of smoothness is worth it.
    func testTheCursorIsExactlyOnThePointItClicked() {
        let raw = jitteryPath()
        let clickTime = raw[30].t
        let smoothed = CursorPath.smoothed(raw, smoothing: .heavy, snappingTo: [clickTime])
        XCTAssertEqual(smoothed[30].point.x, raw[30].point.x, accuracy: 0.001)
        XCTAssertEqual(smoothed[30].point.y, raw[30].point.y, accuracy: 0.001)
    }

    /// Away from the click the smoother is doing its job again — the suspension is local.
    func testSmoothingResumesAwayFromAClick() {
        let raw = jitteryPath()
        let smoothed = CursorPath.smoothed(raw, smoothing: .heavy, snappingTo: [raw[30].t])
        XCTAssertLessThan(wobble(Array(smoothed[0..<24])), wobble(Array(raw[0..<24])))
    }

    // MARK: - Shakes

    /// macOS enlarges the pointer when you shake it. The size never reaches us — we do not capture
    /// the bitmap for known cursors — but the violent zigzag does, and the zoom planner would read
    /// it as activity while the smoother chased it.
    func testAShakeIsReplacedByAStraightLine() {
        var samples = straightPath(count: 40)
        for index in 15..<25 {
            samples[index].point.x = 150 + (index % 2 == 0 ? 90 : -90)
        }
        let cleaned = CursorPath.removingShakes(samples)
        XCTAssertLessThan(wobble(cleaned), wobble(samples) * 0.35)
    }

    func testAnOrdinaryPathIsLeftAlone() {
        let path = straightPath()
        XCTAssertEqual(CursorPath.removingShakes(path), path)
    }

    func testShakeRemovalKeepsEverySample() {
        var samples = straightPath(count: 40)
        for index in 15..<25 { samples[index].point.x = 150 + (index % 2 == 0 ? 90 : -90) }
        XCTAssertEqual(CursorPath.removingShakes(samples).count, 40)
    }

    // MARK: - Looping

    /// A recording meant to loop — a demo GIF, a landing-page hero — has an obvious seam if the
    /// pointer ends far from where it started.
    func testLoopingBringsTheCursorBackToWhereItStarted() {
        let path = straightPath()
        let looped = CursorPath.looped(path, over: 0.4)
        XCTAssertEqual(looped.last?.point.x ?? -1, path.first?.point.x ?? -2, accuracy: 0.5)
        XCTAssertEqual(looped.last?.point.y ?? -1, path.first?.point.y ?? -2, accuracy: 0.5)
    }

    /// Only the tail is rewritten; the demo itself must be untouched.
    func testLoopingLeavesTheStartOfThePathAlone() {
        let path = straightPath()
        let looped = CursorPath.looped(path, over: 0.2)
        XCTAssertEqual(looped[0].point.x, path[0].point.x, accuracy: 0.0001)
        XCTAssertEqual(looped[10].point.x, path[10].point.x, accuracy: 0.0001)
    }

    func testLoopingAnEmptyPathIsSafe() {
        XCTAssertTrue(CursorPath.looped([], over: 1).isEmpty)
    }

    func testLoopingOverNoTimeChangesNothing() {
        let path = straightPath()
        XCTAssertEqual(CursorPath.looped(path, over: 0), path)
    }
}
