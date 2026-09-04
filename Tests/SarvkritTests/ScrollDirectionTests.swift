import XCTest
@testable import Sarvkrit

/// Which way the page was scrolled, and the thresholds the app actually ships.
///
/// Both of these were holes. `offset` searched non-negative shifts only, so a capture scrolled
/// **upward** matched nothing, failed at the first pair and ended the session with a single frame
/// — which is what a user's log said when they reported "the scroll capture did not work". And
/// every existing test loosened `Options` to `minimumOverlap: 4…12, minimumMargin: 0.1`, so the
/// production defaults of `40` and `0.15` had never once been exercised.
final class ScrollDirectionTests: XCTestCase {

    /// A tall page as one hash per row, every row distinct.
    private func page(rows: Int) -> [UInt64] {
        (0..<rows).map { UInt64($0 &* 2_654_435_761 &+ 12_345) }
    }

    private func viewport(_ page: [UInt64], from row: Int, height: Int) -> ScrollFrame {
        ScrollFrame(lines: Array(page[row..<row + height]), width: 100, height: height)
    }

    /// The production options, deliberately not loosened.
    private let shipping = ScrollStitcher.Options()

    func testTheShippingThresholdsAreTheOnesUnderTest() {
        XCTAssertEqual(shipping.minimumOverlap, 40)
        XCTAssertEqual(shipping.minimumMargin, 0.15, accuracy: 0.0001)
    }

    // MARK: - Direction

    func testAPageScrolledDownStitches() {
        let tall = page(rows: 400)
        let frames = stride(from: 0, through: 240, by: 60).map {
            viewport(tall, from: $0, height: 160)
        }
        let plan = ScrollStitcher.plan(frames: frames, axis: .vertical, options: shipping)
        XCTAssertEqual(plan.placements.count, frames.count)
        XCTAssertEqual(plan.totalLength, 400, "160 plus four lots of 60")
    }

    /// The regression test for the reported bug.
    func testAPageScrolledUpStitchesToTheSameThing() {
        let tall = page(rows: 400)
        let rows = Array(stride(from: 0, through: 240, by: 60))
        let down = rows.map { viewport(tall, from: $0, height: 160) }
        let up = rows.reversed().map { viewport(tall, from: $0, height: 160) }

        let planned = ScrollStitcher.plan(frames: up, axis: .vertical, options: shipping)
        if case .noOverlapFound(let index) = planned.endedBecause {
            XCTFail("scrolling up still finds no overlap, at frame \(index)")
        }
        XCTAssertEqual(planned.totalLength,
                       ScrollStitcher.plan(frames: down, axis: .vertical,
                                           options: shipping).totalLength,
                       "the same gesture in reverse must produce the same image")
        XCTAssertEqual(planned.placements.count, up.count)
    }

    func testTheFrameIndicesPointBackAtTheCallersOwnArray() {
        // Reversing internally is only safe if the placements are mapped back — otherwise `render`
        // pairs each range with the wrong bitmap and the image is scrambled rather than empty.
        let tall = page(rows: 400)
        let up = Array(stride(from: 0, through: 240, by: 60)).reversed()
            .map { viewport(tall, from: $0, height: 160) }
        let plan = ScrollStitcher.plan(frames: up, axis: .vertical, options: shipping)

        for placement in plan.placements {
            XCTAssertTrue(up.indices.contains(placement.frameIndex),
                          "frame index \(placement.frameIndex) is outside the input")
        }
        XCTAssertEqual(Set(plan.placements.map(\.frameIndex)).count, plan.placements.count,
                       "each frame should be placed once")
    }

    func testASingleOffsetIsReportedWithItsSign() {
        let tall = page(rows: 300)
        let first = Array(tall[0..<160])
        let scrolledDown = Array(tall[60..<220])

        let down = ScrollStitcher.offset(of: scrolledDown, in: first, minimumOverlap: 40)
        XCTAssertEqual(down?.offset, 60)

        let up = ScrollStitcher.offset(of: first, in: scrolledDown, minimumOverlap: 40)
        XCTAssertEqual(up?.offset, -60, "the same pair the other way round is the negative")
    }

    // MARK: - Still refusing what it should refuse

    func testAUniformPageStillReportsNoMatchRatherThanAConfidentWrongOne() {
        // The margin is the whole point: a blank page matches everywhere equally well. Searching
        // twice as many shifts must not have turned that into a confident answer.
        let blank = [UInt64](repeating: 7, count: 200)
        let match = ScrollStitcher.offset(of: blank, in: blank, minimumOverlap: 40)
        // Either no match, or one with no margin over the runner-up — never a confident offset.
        XCTAssertTrue(match == nil || match!.margin < shipping.minimumMargin,
                      "a uniform page produced a confident offset: \(String(describing: match))")
    }

    func testTwoUnrelatedFramesStillFindNothing() {
        let a = page(rows: 200)
        let b = (0..<200).map { UInt64($0 &* 7_919 &+ 999_983) }
        XCTAssertNil(ScrollStitcher.offset(of: b, in: a, minimumOverlap: 40))
    }

    func testAnOverlapSmallerThanTheMinimumIsRefused() {
        // Scrolling nearly a whole viewport leaves too little to match on, which is the case the
        // session has to prevent by capturing more often rather than hoping.
        let tall = page(rows: 400)
        let first = Array(tall[0..<160])
        let barely = Array(tall[140..<300])
        XCTAssertNil(ScrollStitcher.offset(of: barely, in: first, minimumOverlap: 40),
                     "20 rows of overlap is under the shipping minimum of 40")
    }
}
