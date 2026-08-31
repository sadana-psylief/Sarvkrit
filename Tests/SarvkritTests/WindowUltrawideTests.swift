import XCTest
@testable import Sarvkrit

/// This Mac's display is 3024×1964 — an aspect of 1.54, nowhere near ultrawide. Everything in this
/// file is therefore untestable by hand here, which makes these tests the only check that exists.
final class WindowUltrawideTests: XCTestCase {
    private let wide = CGRect(x: 0, y: 0, width: 3840, height: 1080)      // 32:9
    private let laptop = CGRect(x: 0, y: 0, width: 1600, height: 900)     // 16:9

    private func context(_ frame: CGRect, screen: CGRect, ultrawide: Bool) -> WindowLayout.Context {
        WindowLayout.Context(visibleFrame: screen, currentFrame: frame, isUltrawide: ultrawide)
    }

    // MARK: - Detection

    func testAspectDetection() {
        XCTAssertTrue(WindowLayout.isUltrawide(wide), "32:9 is ultrawide")
        XCTAssertTrue(WindowLayout.isUltrawide(CGRect(x: 0, y: 0, width: 3440, height: 1440)), "21:9")
        XCTAssertFalse(WindowLayout.isUltrawide(laptop), "16:9 is not")
        XCTAssertFalse(WindowLayout.isUltrawide(CGRect(x: 0, y: 0, width: 3024, height: 1964)),
                       "this Mac's own display is not ultrawide")
    }

    func testTheThresholdBoundaryIsInclusive() {
        let exactly = CGRect(x: 0, y: 0, width: 2100, height: 1000)   // exactly 2.1
        let justUnder = CGRect(x: 0, y: 0, width: 2099, height: 1000)
        XCTAssertTrue(WindowLayout.isUltrawide(exactly))
        XCTAssertFalse(WindowLayout.isUltrawide(justUnder))
    }

    func testAZeroHeightScreenIsNotUltrawide() {
        // Guards a divide-by-zero on a display being disconnected mid-query.
        XCTAssertFalse(WindowLayout.isUltrawide(CGRect(x: 0, y: 0, width: 1000, height: 0)))
    }

    // MARK: - Per screen, not global

    func testTheSameSettingGivesThirdsOnWideAndHalvesOnLaptop() {
        // The heart of it: one setting, applied per display. A global flag would get this wrong
        // and give the laptop thirds too.
        let onWide = WindowLayout.rect(for: .leftHalf,
            in: context(CGRect(x: 2000, y: 200, width: 400, height: 400), screen: wide, ultrawide: true))!
        let onLaptop = WindowLayout.rect(for: .leftHalf,
            in: context(CGRect(x: 700, y: 200, width: 400, height: 400), screen: laptop, ultrawide: false))!

        XCTAssertEqual(onWide.width, wide.width / 3, accuracy: 0.01, "wide display should give a third")
        XCTAssertEqual(onLaptop.width, laptop.width / 2, accuracy: 0.01, "laptop should still give a half")
    }

    func testUltrawideOffLeavesHalvesAlone() {
        let r = WindowLayout.rect(for: .leftHalf,
            in: context(CGRect(x: 100, y: 100, width: 400, height: 400), screen: wide, ultrawide: false))!
        XCTAssertEqual(r.width, wide.width / 2, accuracy: 0.01)
    }

    // MARK: - Cycling

    func testLeftCyclesThirdThenHalfThenTwoThirds() {
        let elsewhere = CGRect(x: 2000, y: 200, width: 400, height: 400)

        let first = WindowLayout.rect(for: .leftHalf, in: context(elsewhere, screen: wide, ultrawide: true))!
        XCTAssertEqual(first.width, wide.width / 3, accuracy: 0.01, "first press → third")

        let second = WindowLayout.rect(for: .leftHalf, in: context(first, screen: wide, ultrawide: true))!
        XCTAssertEqual(second.width, wide.width / 2, accuracy: 0.01, "second press → half")

        let third = WindowLayout.rect(for: .leftHalf, in: context(second, screen: wide, ultrawide: true))!
        XCTAssertEqual(third.width, wide.width * 2 / 3, accuracy: 0.01, "third press → two thirds")

        let fourth = WindowLayout.rect(for: .leftHalf, in: context(third, screen: wide, ultrawide: true))!
        XCTAssertEqual(fourth.width, wide.width / 3, accuracy: 0.01, "wraps back to a third")
    }

    func testRightCyclesAndStaysPinnedToTheRightEdge() {
        let elsewhere = CGRect(x: 0, y: 200, width: 400, height: 400)

        let first = WindowLayout.rect(for: .rightHalf, in: context(elsewhere, screen: wide, ultrawide: true))!
        XCTAssertEqual(first.maxX, wide.maxX, accuracy: 0.01)
        XCTAssertEqual(first.width, wide.width / 3, accuracy: 0.01)

        let second = WindowLayout.rect(for: .rightHalf, in: context(first, screen: wide, ultrawide: true))!
        XCTAssertEqual(second.maxX, wide.maxX, accuracy: 0.01, "must stay against the right edge")
        XCTAssertEqual(second.width, wide.width / 2, accuracy: 0.01)
    }

    func testCyclingToleratesAppsThatQuantizeTheirSize() {
        // Terminal and friends round their size to whole character cells, so the frame you read
        // back is never exactly the frame you set. Exact matching would break cycling on precisely
        // those apps — the window would sit on "third" forever.
        let exactThird = WindowLayout.rect(for: .leftHalf,
            in: context(CGRect(x: 2000, y: 0, width: 10, height: 10), screen: wide, ultrawide: true))!
        let quantized = CGRect(x: exactThird.minX + 3, y: exactThird.minY - 2,
                               width: exactThird.width - 5, height: exactThird.height + 4)

        let next = WindowLayout.rect(for: .leftHalf, in: context(quantized, screen: wide, ultrawide: true))!
        XCTAssertEqual(next.width, wide.width / 2, accuracy: 0.01,
                       "a few points off should still count as ‘currently a third’")
    }

    func testAFrameWellOutsideToleranceStartsTheCycleOver() {
        let exactThird = WindowLayout.rect(for: .leftHalf,
            in: context(CGRect(x: 2000, y: 0, width: 10, height: 10), screen: wide, ultrawide: true))!
        let farOff = exactThird.insetBy(dx: -80, dy: 0)

        let next = WindowLayout.rect(for: .leftHalf, in: context(farOff, screen: wide, ultrawide: true))!
        XCTAssertEqual(next.width, wide.width / 3, accuracy: 0.01)
    }

    // MARK: - Maximize

    func testMaximizeIsCappedAndCentredOnUltrawide() {
        // Filling a 32:9 display is something almost nobody wants.
        let r = WindowLayout.rect(for: .maximize,
            in: context(.zero, screen: wide, ultrawide: true))!
        XCTAssertLessThan(r.width, wide.width)
        XCTAssertEqual(r.width, wide.width * 2 / 3, accuracy: 0.01)
        XCTAssertEqual(r.midX, wide.midX, accuracy: 0.01, "should be centred")
        XCTAssertEqual(r.height, wide.height, accuracy: 0.01, "full height is still wanted")
    }

    func testMaximizeStillFillsANormalScreen() {
        let r = WindowLayout.rect(for: .maximize,
            in: context(.zero, screen: laptop, ultrawide: false))!
        XCTAssertEqual(r, laptop)
    }

    func testTheMaxWidthFractionIsConfigurable() {
        var ctx = context(.zero, screen: wide, ultrawide: true)
        ctx.ultrawideMaxWidthFraction = 0.5
        XCTAssertEqual(WindowLayout.rect(for: .maximize, in: ctx)!.width,
                       wide.width / 2, accuracy: 0.01)
    }
}
