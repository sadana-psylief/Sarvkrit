import XCTest
@testable import Sarvkrit

/// What to do at launch about a fan that is already being held.
///
/// The same shape as `KeepAwakeState.action(for:)`, and for the same reason: getting it wrong
/// either strands a fan or stamps on a setting somebody else made deliberately, and neither
/// failure announces itself.
final class FanReconcileTests: XCTestCase {

    private func action(weForcedIt: Bool, modeIsForced: Bool, wantsControl: Bool)
        -> FanReconcile.Action {
        FanReconcile.action(for: .init(
            weForcedIt: weForcedIt, modeIsForced: modeIsForced, wantsControl: wantsControl))
    }

    func testNothingToDoWhenNobodyIsHoldingTheFan() {
        XCTAssertEqual(action(weForcedIt: false, modeIsForced: false, wantsControl: false),
                       .doNothing)
    }

    func testWantingControlOfAFreeFanMeansTakingIt() {
        XCTAssertEqual(action(weForcedIt: false, modeIsForced: false, wantsControl: true),
                       .takeControl)
    }

    /// Our helper should have released it on the way out, so this is a helper that died badly —
    /// or a Mac that lost power. Offer rather than ambush: clearing it costs a password, and a
    /// prompt nobody asked for at launch is how an app teaches people to click through prompts.
    func testAFanWeLeftHeldIsOfferedBackRatherThanReleasedBehindAPrompt() {
        XCTAssertEqual(action(weForcedIt: true, modeIsForced: true, wantsControl: false),
                       .offerToRelease)
    }

    /// Macs Fan Control, TG Pro, somebody's script. Not ours to undo.
    func testAFanSomebodyElseIsHoldingIsLeftAlone() {
        XCTAssertEqual(action(weForcedIt: false, modeIsForced: true, wantsControl: false),
                       .doNothing)
    }

    func testAFanAlreadyHeldForUsNeedsNothingDoing() {
        XCTAssertEqual(action(weForcedIt: true, modeIsForced: true, wantsControl: true),
                       .doNothing)
    }

    /// We think we are holding it and the SMC says otherwise — a sleep cycle dropped the mode.
    /// Take it again rather than reporting control we do not have.
    func testAFanThatSlippedOutOfOurGripIsTakenAgain() {
        XCTAssertEqual(action(weForcedIt: true, modeIsForced: false, wantsControl: true),
                       .takeControl)
    }

    func testAStaleBeliefAboutAFanWeNoLongerWantIsJustForgotten() {
        XCTAssertEqual(action(weForcedIt: true, modeIsForced: false, wantsControl: false),
                       .doNothing)
    }
}
