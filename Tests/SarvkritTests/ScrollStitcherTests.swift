import XCTest
@testable import Sarvkrit

/// Fixtures are arrays of line hashes, not bitmaps, which is the point of reducing frames to
/// signatures: the entire stitching algorithm is testable by reading numbers.
final class ScrollStitcherTests: XCTestCase {
    private let options = ScrollStitcher.Options(minimumOverlap: 4, minimumMargin: 0.1,
                                                 frameLimit: 40)

    /// A "page" of distinct lines. `content(from:count:)` takes a window of it, the way a
    /// scrolling viewport does.
    private func content(from start: Int, count: Int) -> [UInt64] {
        (start..<(start + count)).map { UInt64($0 &* 2_654_435_761 &+ 1) }
    }

    private func frame(_ lines: [UInt64]) -> ScrollFrame {
        ScrollFrame(lines: lines, width: 100, height: lines.count)
    }

    // MARK: - Offset

    func testItFindsAHalfScreenScroll() {
        let a = content(from: 0, count: 20)
        let b = content(from: 10, count: 20)
        let match = try! XCTUnwrap(ScrollStitcher.offset(of: b, in: a, minimumOverlap: 4))
        XCTAssertEqual(match.offset, 10)
        XCTAssertEqual(match.score, 1.0, accuracy: 0.001)
    }

    func testIdenticalFramesMatchAtZero() {
        let a = content(from: 0, count: 20)
        XCTAssertEqual(ScrollStitcher.offset(of: a, in: a, minimumOverlap: 4)?.offset, 0)
    }

    func testAUniformPageProducesNoConfidentMatch() {
        // The margin rule. A page of solid background matches equally well at every offset, and a
        // confident wrong answer there silently mangles the image — where admitting failure can
        // be retried.
        let flat = [UInt64](repeating: 7, count: 20)
        let match = ScrollStitcher.offset(of: flat, in: flat, minimumOverlap: 4)
        XCTAssertEqual(match?.margin ?? 0, 0, accuracy: 0.0001,
                       "a uniform page must not look like a confident match")
    }

    func testCompletelyDifferentContentDoesNotMatch() {
        XCTAssertNil(ScrollStitcher.offset(of: content(from: 500, count: 20),
                                           in: content(from: 0, count: 20),
                                           minimumOverlap: 4))
    }

    func testAnEmptyInputMatchesNothing() {
        XCTAssertNil(ScrollStitcher.offset(of: [], in: content(from: 0, count: 10),
                                           minimumOverlap: 1))
        XCTAssertNil(ScrollStitcher.offset(of: content(from: 0, count: 10), in: [],
                                           minimumOverlap: 1))
    }

    // MARK: - Planning

    func testTwoFramesWithHalfOverlapProduceOneAndAHalfScreens() {
        let plan = ScrollStitcher.plan(
            frames: [frame(content(from: 0, count: 20)), frame(content(from: 10, count: 20))],
            axis: .vertical, options: options)
        XCTAssertEqual(plan.totalLength, 30)
        XCTAssertEqual(plan.endedBecause, .contentExhausted)
    }

    func testAPlanNeverWritesTheSameDestinationLineTwice() {
        // The invariant that catches every off-by-one in the offsets.
        let frames = (0..<5).map { frame(content(from: $0 * 7, count: 20)) }
        let plan = ScrollStitcher.plan(frames: frames, axis: .vertical, options: options)

        var written = Set<Int>()
        for placement in plan.placements {
            for line in 0..<placement.sourceRange.count {
                let destination = placement.destinationOffset + line
                XCTAssertTrue(written.insert(destination).inserted,
                              "line \(destination) written twice")
            }
        }
        XCTAssertEqual(written.count, plan.totalLength)
    }

    func testAFrameIdenticalToItsPredecessorEndsTheCapture() {
        let page = content(from: 0, count: 20)
        let plan = ScrollStitcher.plan(frames: [frame(page), frame(page)],
                                       axis: .vertical, options: options)
        XCTAssertEqual(plan.endedBecause, .contentExhausted)
        XCTAssertEqual(plan.totalLength, 20, "a repeated frame must add nothing")
    }

    func testMomentumOvershootWithNoOverlapIsReportedNotGuessed() {
        let plan = ScrollStitcher.plan(
            frames: [frame(content(from: 0, count: 20)), frame(content(from: 900, count: 20))],
            axis: .vertical, options: options)
        XCTAssertEqual(plan.endedBecause, .noOverlapFound(atFrame: 1))
    }

    func testTheFrameLimitIsReportedRatherThanSilentlyTruncating() {
        let frames = (0..<60).map { frame(content(from: $0 * 3, count: 20)) }
        let plan = ScrollStitcher.plan(
            frames: frames, axis: .vertical,
            options: ScrollStitcher.Options(minimumOverlap: 4, minimumMargin: 0.1, frameLimit: 5))
        XCTAssertEqual(plan.endedBecause, .frameLimit)
    }

    func testASingleFrameIsItsOwnPlan() {
        let plan = ScrollStitcher.plan(frames: [frame(content(from: 0, count: 20))],
                                       axis: .vertical, options: options)
        XCTAssertEqual(plan.totalLength, 20)
        XCTAssertEqual(plan.placements.count, 1)
    }

    func testNoFramesIsNotACrash() {
        let plan = ScrollStitcher.plan(frames: [], axis: .vertical, options: options)
        XCTAssertEqual(plan.totalLength, 0)
        XCTAssertTrue(plan.placements.isEmpty)
    }

    // MARK: - Sticky regions

    func testAStickyHeaderIsWrittenOnceNotOncePerFrame() {
        let header: [UInt64] = [1, 2, 3]
        let frames = (0..<4).map { frame(header + content(from: $0 * 5, count: 20)) }
        let plan = ScrollStitcher.plan(frames: frames, axis: .vertical, options: options)

        XCTAssertEqual(plan.stickyLeading, 3)
        // Header once, plus the first body, plus 5 new lines per later frame.
        XCTAssertEqual(plan.totalLength, 3 + 20 + 5 * 3)
    }

    func testAStickyFooterIsWrittenOnceAndOnlyAtTheEnd() {
        let footer: [UInt64] = [98, 99]
        let frames = (0..<3).map { frame(content(from: $0 * 5, count: 20) + footer) }
        let plan = ScrollStitcher.plan(frames: frames, axis: .vertical, options: options)

        XCTAssertEqual(plan.stickyTrailing, 2)
        let last = try! XCTUnwrap(plan.placements.last)
        XCTAssertEqual(last.destinationOffset + last.sourceRange.count, plan.totalLength,
                       "the footer must be the last thing written")
    }

    func testIdenticalFramesAreNotMistakenForAnEntirelyStickyPage() {
        let page = content(from: 0, count: 20)
        let regions = ScrollStitcher.stickyRegions(in: [frame(page), frame(page)])
        XCTAssertEqual(regions.leading, 0)
        XCTAssertEqual(regions.trailing, 0)
    }

    func testASingleFrameHasNoStickyRegions() {
        let regions = ScrollStitcher.stickyRegions(in: [frame(content(from: 0, count: 10))])
        XCTAssertEqual(regions.leading, 0)
        XCTAssertEqual(regions.trailing, 0)
    }

    // MARK: - Horizontal

    func testHorizontalIsTheSameAlgorithmOverColumns() {
        let plan = ScrollStitcher.plan(
            frames: [frame(content(from: 0, count: 20)), frame(content(from: 10, count: 20))],
            axis: .horizontal, options: options)
        XCTAssertEqual(plan.totalLength, 30)
    }
}

/// The one test here that touches CoreGraphics, because a plan that is correct over integers can
/// still be blitted wrong.
final class ScrollStitcherRenderTests: XCTestCase {

    /// A tall image of numbered horizontal stripes, one distinct colour per row band.
    private func stripes(width: Int, height: Int, from: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<height {
            let value = Double((from + row) % 255) / 255.0
            context.setFillColor(CGColor(red: value, green: 1 - value, blue: 0.5, alpha: 1))
            // Flipped: row 0 is the top, CGContext's origin is the bottom.
            context.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testARoundTripReconstructsTheOriginal() throws {
        let width = 60, viewport = 40, step = 15
        let images = try (0..<3).map { try stripes(width: width, height: viewport,
                                                   from: $0 * step) }
        let frames = images.map {
            ScrollFrame(lines: ImageLineSignature.signatures(of: $0, axis: .vertical),
                        width: $0.width, height: $0.height)
        }

        let plan = ScrollStitcher.plan(
            frames: frames, axis: .vertical,
            options: ScrollStitcher.Options(minimumOverlap: 8, minimumMargin: 0.1, frameLimit: 40))
        XCTAssertEqual(plan.totalLength, viewport + step * 2)

        let stitched = try XCTUnwrap(ScrollStitcher.render(plan, images: images, axis: .vertical))
        XCTAssertEqual(stitched.width, width)
        XCTAssertEqual(stitched.height, viewport + step * 2)
    }

    func testSignaturesAreStableAndDiscriminating() throws {
        let a = try stripes(width: 40, height: 20, from: 0)
        let b = try stripes(width: 40, height: 20, from: 0)
        let c = try stripes(width: 40, height: 20, from: 5)

        XCTAssertEqual(ImageLineSignature.signatures(of: a, axis: .vertical),
                       ImageLineSignature.signatures(of: b, axis: .vertical),
                       "identical images must hash identically")
        XCTAssertNotEqual(ImageLineSignature.signatures(of: a, axis: .vertical),
                          ImageLineSignature.signatures(of: c, axis: .vertical))
    }

    func testAChangeInTheOuterMarginDoesNotChangeTheSignatures() throws {
        // Only the middle 60% is hashed, so a scrollbar appearing at the edge must not make two
        // frames of the same content look different.
        let plain = try stripes(width: 100, height: 20, from: 0)

        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(plain, in: CGRect(x: 0, y: 0, width: 100, height: 20))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 90, y: 0, width: 10, height: 20))   // a scrollbar
        let withScrollbar = try XCTUnwrap(context.makeImage())

        XCTAssertEqual(ImageLineSignature.signatures(of: plain, axis: .vertical),
                       ImageLineSignature.signatures(of: withScrollbar, axis: .vertical))
    }
}
