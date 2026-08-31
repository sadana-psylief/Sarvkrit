import XCTest
@testable import Sarvkrit

/// The geometry is pure, so nearly all of window management is testable here rather than by
/// dragging windows around and squinting at them.
final class WindowLayoutTests: XCTestCase {
    /// A plain 16:9 screen, origin away from zero so an implementation that ignores the origin
    /// fails rather than passing by luck.
    private let screen = CGRect(x: 100, y: 50, width: 1600, height: 900)
    /// 32:9.
    private let ultrawide = CGRect(x: 0, y: 0, width: 3840, height: 1080)

    private func context(
        _ frame: CGRect? = nil,
        screen: CGRect? = nil,
        ultrawide: Bool = false
    ) -> WindowLayout.Context {
        let s = screen ?? self.screen
        return WindowLayout.Context(
            visibleFrame: s,
            currentFrame: frame ?? CGRect(x: s.midX - 200, y: s.midY - 150, width: 400, height: 300),
            isUltrawide: ultrawide
        )
    }

    private func rect(_ action: WindowAction, _ ctx: WindowLayout.Context? = nil) -> CGRect {
        WindowLayout.rect(for: action, in: ctx ?? context())!
    }

    // MARK: - Everything produces something sane

    func testEveryActionEitherProducesARectOrIsExplicitlyOwnedElsewhere() {
        for action in WindowAction.allCases {
            let result = WindowLayout.rect(for: action, in: context())
            if action == .restore || action.isDisplayMove {
                XCTAssertNil(result, "\(action) should be handled outside the geometry")
            } else {
                XCTAssertNotNil(result, "\(action) produced no rect")
            }
        }
    }

    func testNoActionEverLeavesTheScreen() {
        // A window placed outside its display is unreachable without a mouse.
        for action in WindowAction.allCases {
            guard let r = WindowLayout.rect(for: action, in: context()) else { continue }
            XCTAssertGreaterThanOrEqual(r.minX, screen.minX - 0.01, "\(action) overflows left")
            XCTAssertGreaterThanOrEqual(r.minY, screen.minY - 0.01, "\(action) overflows bottom")
            XCTAssertLessThanOrEqual(r.maxX, screen.maxX + 0.01, "\(action) overflows right")
            XCTAssertLessThanOrEqual(r.maxY, screen.maxY + 0.01, "\(action) overflows top")
        }
    }

    // MARK: - Halves and corners

    func testHalvesSplitTheScreenExactly() {
        XCTAssertEqual(rect(.leftHalf), CGRect(x: 100, y: 50, width: 800, height: 900))
        XCTAssertEqual(rect(.rightHalf), CGRect(x: 900, y: 50, width: 800, height: 900))
    }

    func testLeftAndRightHalvesTileWithoutGapOrOverlap() {
        let left = rect(.leftHalf), right = rect(.rightHalf)
        XCTAssertEqual(left.maxX, right.minX, "a gap or overlap between the halves")
        XCTAssertEqual(left.width + right.width, screen.width)
    }

    func testTopHalfIsAboveBottomHalf() {
        // The bug this catches: rows measured from the wrong end, so "top" lands at the bottom.
        XCTAssertGreaterThan(rect(.topHalf).minY, rect(.bottomHalf).minY)
        XCTAssertEqual(rect(.topHalf).maxY, screen.maxY)
        XCTAssertEqual(rect(.bottomHalf).minY, screen.minY)
    }

    func testCornersTileTheScreen() {
        let corners = [rect(.topLeft), rect(.topRight), rect(.bottomLeft), rect(.bottomRight)]
        XCTAssertEqual(corners.reduce(0) { $0 + $1.width * $1.height }, screen.width * screen.height)
        XCTAssertEqual(rect(.topLeft).minX, screen.minX)
        XCTAssertEqual(rect(.topLeft).maxY, screen.maxY)
        XCTAssertEqual(rect(.bottomRight).maxX, screen.maxX)
        XCTAssertEqual(rect(.bottomRight).minY, screen.minY)
    }

    // MARK: - Thirds, fourths, sixths tile cleanly

    func testThirdsTileTheScreen() {
        let parts = [rect(.firstThird), rect(.centerThird), rect(.lastThird)]
        XCTAssertEqual(parts[0].maxX, parts[1].minX, accuracy: 0.01)
        XCTAssertEqual(parts[1].maxX, parts[2].minX, accuracy: 0.01)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.width }, screen.width, accuracy: 0.01)
    }

    func testFourthsTileTheScreen() {
        let parts = [rect(.firstFourth), rect(.secondFourth), rect(.thirdFourth), rect(.lastFourth)]
        for (a, b) in zip(parts, parts.dropFirst()) {
            XCTAssertEqual(a.maxX, b.minX, accuracy: 0.01)
        }
        XCTAssertEqual(parts.reduce(0) { $0 + $1.width }, screen.width, accuracy: 0.01)
    }

    func testSixthsTileTheScreenAsAThreeByTwoGrid() {
        let all: [WindowAction] = [.topLeftSixth, .topCenterSixth, .topRightSixth,
                                   .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth]
        let area = all.reduce(CGFloat(0)) { $0 + rect($1).width * rect($1).height }
        XCTAssertEqual(area, screen.width * screen.height, accuracy: 0.01)
        XCTAssertGreaterThan(rect(.topLeftSixth).minY, rect(.bottomLeftSixth).minY)
        XCTAssertEqual(rect(.topLeftSixth).width, screen.width / 3, accuracy: 0.01)
    }

    func testTwoThirdsAndThreeFourthsSpanTheRightAmount() {
        XCTAssertEqual(rect(.firstTwoThirds).width, screen.width * 2 / 3, accuracy: 0.01)
        XCTAssertEqual(rect(.lastTwoThirds).maxX, screen.maxX, accuracy: 0.01)
        XCTAssertEqual(rect(.firstThreeFourths).width, screen.width * 3 / 4, accuracy: 0.01)
    }

    // MARK: - Size actions

    func testMaximizeFillsTheVisibleFrame() {
        XCTAssertEqual(rect(.maximize), screen)
    }

    func testAlmostMaximizeLeavesAMarginAndStaysCentred() {
        let r = rect(.almostMaximize)
        XCTAssertLessThan(r.width, screen.width)
        XCTAssertEqual(r.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(r.midY, screen.midY, accuracy: 0.01)
    }

    func testMaximizeHeightKeepsWidthAndPosition() {
        let current = CGRect(x: 300, y: 400, width: 500, height: 200)
        let r = rect(.maximizeHeight, context(current))
        XCTAssertEqual(r.minX, current.minX)
        XCTAssertEqual(r.width, current.width)
        XCTAssertEqual(r.height, screen.height)
    }

    func testCenterKeepsSize() {
        let current = CGRect(x: 0, y: 0, width: 640, height: 480)
        let r = rect(.center, context(current))
        XCTAssertEqual(r.size, current.size)
        XCTAssertEqual(r.midX, screen.midX, accuracy: 0.01)
    }

    func testMakeSmallerAndLargerMoveInTheRightDirection() {
        let current = CGRect(x: 500, y: 300, width: 800, height: 500)
        XCTAssertLessThan(rect(.makeSmaller, context(current)).width, current.width)
        XCTAssertGreaterThan(rect(.makeLarger, context(current)).width, current.width)
    }

    func testMakeSmallerCannotShrinkAWindowToNothing() {
        var frame = CGRect(x: 800, y: 400, width: 400, height: 300)
        for _ in 0..<50 { frame = rect(.makeSmaller, context(frame)) }
        XCTAssertGreaterThanOrEqual(frame.width, 200, "shrank past a usable size")
        XCTAssertGreaterThanOrEqual(frame.height, 150)
    }

    func testMakeLargerCannotGrowPastTheScreen() {
        var frame = CGRect(x: 500, y: 300, width: 400, height: 300)
        for _ in 0..<50 { frame = rect(.makeLarger, context(frame)) }
        XCTAssertLessThanOrEqual(frame.width, screen.width)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX + 0.01)
    }

    // MARK: - Nudging

    func testNudgeMovesInTheExpectedDirection() {
        let current = CGRect(x: 700, y: 400, width: 400, height: 300)
        XCTAssertLessThan(rect(.moveLeft, context(current)).minX, current.minX)
        XCTAssertGreaterThan(rect(.moveRight, context(current)).minX, current.minX)
        XCTAssertGreaterThan(rect(.moveUp, context(current)).minY, current.minY, "up is +Y in Cocoa")
        XCTAssertLessThan(rect(.moveDown, context(current)).minY, current.minY)
    }

    func testNudgeStopsAtTheEdgeRatherThanWalkingOffScreen() {
        var frame = CGRect(x: 700, y: 400, width: 400, height: 300)
        for _ in 0..<200 { frame = rect(.moveLeft, context(frame)) }
        XCTAssertEqual(frame.minX, screen.minX, accuracy: 0.01)

        for _ in 0..<200 { frame = rect(.moveUp, context(frame)) }
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
    }

    // MARK: - Reachability in the settings pane

    func testEveryActionIsReachableFromExactlyOneGroupInThePane() {
        // The pane renders strictly group by group, so an action whose group is never rendered is
        // invisible and unbindable — the same failure, arrived at differently, as the group
        // headers that couldn't be opened.
        let grouped = WindowAction.Group.allCases.flatMap { group in
            WindowAction.allCases.filter { $0.group == group }
        }
        XCTAssertEqual(grouped.count, WindowAction.allCases.count,
                       "an action belongs to no rendered group and cannot be bound")
        XCTAssertEqual(Set(grouped), Set(WindowAction.allCases))
    }
}
