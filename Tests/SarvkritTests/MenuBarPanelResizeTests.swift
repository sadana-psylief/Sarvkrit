import CoreGraphics
import XCTest
@testable import Sarvkrit

/// When the tray panel animates its height, and between which frames.
///
/// Pure, for the reason `MenuBarPanelPlacementTests` gives about position and this file needs
/// about timing: a resize landing mid-animation, the first placement of a presentation, and
/// Reduce Motion are states you cannot hold a panel in long enough to look at.
final class MenuBarPanelResizeTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let width: CGFloat = 420
    private let anchorTop: CGFloat = 947
    private let x: CGFloat = 731

    /// The frame the window has when it is `height` tall and correctly anchored.
    private func anchored(_ height: CGFloat) -> CGRect {
        MenuBarPanelResize.frame(
            forHeight: height, x: x, top: anchorTop, width: width, in: visible)
    }

    private func step(
        window: CGRect,
        settled: CGFloat,
        content: CGFloat,
        inFlightTo: CGRect? = nil,
        animates: Bool = true
    ) -> MenuBarPanelResize.Step {
        MenuBarPanelResize.step(
            window: window, settledHeight: settled, contentHeight: content,
            inFlightTo: inFlightTo, anchorTop: anchorTop, visible: visible, animates: animates)
    }

    // MARK: - The bug

    func testAGrowAnimatesFromTheHeightItHadNotFromTheOneSwiftUIJumpedTo() throws {
        // The reported bug, in numbers. Measured on a Keyboard → Files switch: the content went
        // 338 → 533, and SwiftUI had already set the window to 533 before the first content report
        // arrived. Animating from *there* is a zero-length animation, and the old code's answer —
        // dragging the window down to whatever height the content animation was currently at, ~25
        // times in 150ms — is the 195pt flicker the user was reporting.
        let step = step(window: anchored(533), settled: 338, content: 533)

        guard case .animate(let from, let to) = step else {
            return XCTFail("a content-height change is the one thing worth animating, got \(step)")
        }
        XCTAssertEqual(from.height, 338, "the animation started where SwiftUI jumped to, not where the panel was")
        XCTAssertEqual(to.height, 533)
    }

    func testEveryMeasuredGrowKeepsTheTopEdgeStillForTheWholeAnimation() throws {
        // `from.maxY == to.maxY` is what makes the top edge stay put: interpolating the whole rect
        // moves the origin by Δy = −Δh, so y(t) + h(t) is constant. If these ever disagreed the
        // panel would slide during the resize however smooth the resize itself was.
        for pair in [(286, 338), (338, 533), (351, 533)] as [(CGFloat, CGFloat)] {
            let step = step(window: anchored(pair.0), settled: pair.0, content: pair.1)
            guard case .animate(let from, let to) = step else {
                return XCTFail("\(pair.0) -> \(pair.1) did not animate, got \(step)")
            }
            XCTAssertEqual(from.height, pair.0, "\(pair)")
            XCTAssertEqual(to.height, pair.1, "\(pair)")
            XCTAssertEqual(from.maxY, anchorTop, "\(pair) starts off the anchor")
            XCTAssertEqual(to.maxY, anchorTop, "\(pair) ends off the anchor")
        }
    }

    func testEveryMeasuredShrinkSnaps() {
        // A shrink has nothing to reveal — the content is already short and against the top edge,
        // so an animation only drags the bottom edge up through empty material. Snapping puts the
        // window and its content in agreement immediately.
        for pair in [(533, 351), (400, 300), (338, 286)] as [(CGFloat, CGFloat)] {
            XCTAssertEqual(
                step(window: anchored(pair.0), settled: pair.0, content: pair.1),
                .set(anchored(pair.1)), "\(pair)")
        }
    }

    func testAGrowRewindsPastTheHeightSwiftUIAlreadyJumpedTo() throws {
        // The asymmetry the whole design turns on: SwiftUI resizes this window on a grow and does
        // nothing at all on a shrink. So on a grow the window is *already* at the destination when
        // this runs, and the animation has to be given somewhere to start from.
        let step = step(window: anchored(533), settled: 338, content: 533)

        guard case .animate(let from, let to) = step else { return XCTFail("expected an animation") }
        XCTAssertEqual(from.height, 338, "the rewind is what makes a grow visible at all")
        XCTAssertEqual(to.height, 533)
    }

    // MARK: - Not animating

    func testReduceMotionSnapsAndNeverAnimates() {
        // A shrink, because that is where Reduce Motion has work to do: SwiftUI does not resize on
        // a shrink, so the window is still 533 tall around 351pt of content and something has to
        // move it. On a grow SwiftUI has already jumped the window to the settled height, so the
        // honest answer there is `.none` — the panel is the right size, just not because of us.
        XCTAssertEqual(
            step(window: anchored(533), settled: 533, content: 351, animates: false),
            .set(anchored(351)))
        XCTAssertEqual(
            step(window: anchored(533), settled: 338, content: 533, animates: false),
            .none)

        // Whatever the direction, it must never be an animation.
        for pair in [(286, 338), (338, 533), (533, 351), (400, 300)] as [(CGFloat, CGFloat)] {
            let step = step(window: anchored(pair.0), settled: pair.0, content: pair.1, animates: false)
            if case .animate = step { XCTFail("\(pair) animated with Reduce Motion on") }
        }
    }

    func testReduceMotionSwitchedOnMidAnimationLandsThePanelRatherThanFinishingTheMove() {
        // Checked before the in-flight case on purpose: "never animate" has to mean never, and
        // finishing a movement the user has just asked not to see is the wrong reading.
        XCTAssertEqual(
            step(window: anchored(400), settled: 338, content: 533,
                 inFlightTo: anchored(533), animates: false),
            .set(anchored(533)))
    }

    func testTheFirstPlacementOfAPresentationDoesNotAnimate() {
        // The panel must appear at its size. `MenuBarExtra` has its own opening animation, and
        // growing into place on top of it reads as a stutter rather than as motion.
        XCTAssertEqual(
            step(window: CGRect(x: x, y: 0, width: width, height: 100), settled: 0, content: 533),
            .set(anchored(533)))
    }

    func testDriftIsCorrectedButNotPerformed() {
        // The content height did not change, so whatever moved the window was not the user doing
        // anything. Animation is how this panel says "the content changed"; spending it on a
        // stale origin would be motion that explains nothing.
        let drifted = CGRect(x: x, y: anchorTop - 533 - 40, width: width, height: 533)
        XCTAssertEqual(step(window: drifted, settled: 533, content: 533), .set(anchored(533)))
    }

    func testAPanelAlreadyWhereItBelongsIsLeftAlone() {
        XCTAssertEqual(step(window: anchored(533), settled: 533, content: 533), .none)
    }

    func testNothingHappensBeforeTheContentHasBeenLaidOut() {
        // Sizing a window to zero is worse than leaving it at whatever the system chose.
        XCTAssertEqual(step(window: anchored(533), settled: 533, content: 0), .none)
    }

    func testASubPixelContentChangeIsNotWorthAnAnimation() {
        XCTAssertEqual(step(window: anchored(533), settled: 533, content: 533.3), .none)
    }

    // MARK: - A resize arriving mid-animation

    func testARepeatedReportOfTheHeightAlreadyBeingAnimatedToIsIgnored() {
        // The animation generates ~50 resize notifications of its own and the probe lays out
        // repeatedly; without this the panel would restart its animation on every frame and never
        // arrive.
        XCTAssertEqual(
            step(window: anchored(400), settled: 338, content: 533, inFlightTo: anchored(533)),
            .none)
    }

    func testANewDestinationMidAnimationRestartsFromWhereTheWindowHasGotTo() throws {
        // A fast double tab switch, or the Volume Mixer's app list changing height inside the
        // 150ms. Starting again from the height the first animation began at would jump the panel
        // backwards before setting off.
        let midFlight = anchored(400)
        let step = step(window: midFlight, settled: 338, content: 620, inFlightTo: anchored(533))

        guard case .animate(let from, let to) = step else { return XCTFail("expected an animation") }
        XCTAssertTrue(MenuBarPanelResize.same(from, midFlight),
                      "the new animation should start from the window's current frame")
        XCTAssertEqual(to.height, 620)
        XCTAssertEqual(from.maxY, anchorTop)
        XCTAssertEqual(to.maxY, anchorTop)
    }

    func testTheVolumeMixerGainingARowAnimatesLikeAnyOtherGrow() throws {
        // `VolumeMixerTrayView` is one row per app making sound, so the panel changes height while
        // it is open and nobody has touched it. An app starting to play grows the panel and
        // animates; one stopping snaps, like every other shrink.
        let row = Theme.Metrics.panelRowHeight
        guard case .animate(let from, let to) = step(window: anchored(533), settled: 533, content: 533 + row)
        else { return XCTFail("expected an animation") }
        XCTAssertEqual(from.height, 533)
        XCTAssertEqual(to.height, 533 + row)

        XCTAssertEqual(step(window: anchored(533), settled: 533, content: 533 - row),
                       .set(anchored(533 - row)), "an app stopping is a shrink, and shrinks snap")
    }

    // MARK: - Position is still `MenuBarPanelPlacement`'s answer

    func testATallPanelStillOverflowsTheBottomRatherThanLiftingOffItsIcon() {
        // Deferred entirely to `MenuBarPanelPlacement`, and asserted here so that adding a resize
        // animation cannot quietly introduce a lower clamp of its own.
        let frame = MenuBarPanelResize.frame(
            forHeight: 1200, x: x, top: anchorTop, width: width, in: visible)
        XCTAssertEqual(frame.maxY, anchorTop)
        XCTAssertLessThan(frame.minY, visible.minY)
    }
}
