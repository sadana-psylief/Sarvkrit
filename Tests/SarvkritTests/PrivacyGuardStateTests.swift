import XCTest
@testable import Sarvkrit

/// The microphone lock, and specifically its refusal to fight itself.
///
/// A lock that treats its own re-assert as external interference oscillates: mute, notice a change,
/// mute again, forever. That is not a harmless loop — it is a microphone flapping between live and
/// silent in the middle of a call, which is worse than either state.
final class PrivacyGuardStateTests: XCTestCase {

    private func locked() -> PrivacyGuardState {
        var state = PrivacyGuardState()
        state.isLocked = true
        return state
    }

    // MARK: - The loop

    func testOurOwnMuteIsNotTreatedAsInterference() {
        var state = locked()
        state.willAssertMute()
        XCTAssertEqual(state.handle(.becameMuted), .doNothing)
        XCTAssertFalse(state.isAwaitingOwnMute, "the expectation must be discharged, not accumulate")
    }

    func testAMuteWeDidNotAskForAlsoNeedsNoAction() {
        // Somebody else muted it. That's the state we wanted anyway.
        var state = locked()
        XCTAssertEqual(state.handle(.becameMuted), .doNothing)
    }

    func testRepeatedMutesDoNotAccumulateExpectations() {
        // If each assert left an expectation behind, a later genuine unmute could be swallowed.
        var state = locked()
        for _ in 0..<5 {
            state.willAssertMute()
            _ = state.handle(.becameMuted)
        }
        XCTAssertFalse(state.isAwaitingOwnMute)
        XCTAssertEqual(state.handle(.becameUnmuted), .reassertMute,
                       "an unmute after all that must still be caught")
    }

    // MARK: - Doing its job

    func testAnExternalUnmuteIsReverted() {
        var state = locked()
        XCTAssertEqual(state.handle(.becameUnmuted), .reassertMute)
    }

    func testAnUnmuteIsRevertedEvenWithAMutePending() {
        // The lock only ever mutes, so a pending expectation can't belong to an unmute — it's stale
        // and must not suppress a real one. Getting this wrong means the lock silently fails exactly
        // once, at a moment nobody would think to check.
        var state = locked()
        state.willAssertMute()
        XCTAssertEqual(state.handle(.becameUnmuted), .reassertMute)
    }

    func testTheLockKeepsWorkingAfterReverting() {
        var state = locked()
        _ = state.handle(.becameUnmuted)
        state.willAssertMute()
        _ = state.handle(.becameMuted)
        XCTAssertEqual(state.handle(.becameUnmuted), .reassertMute)
    }

    // MARK: - Unlocked

    func testNothingIsRevertedWhileUnlocked() {
        var state = PrivacyGuardState()
        XCTAssertEqual(state.handle(.becameUnmuted), .doNothing)
        XCTAssertEqual(state.handle(.becameMuted), .doNothing)
    }

    func testUnlockingStopsTheReverting() {
        var state = locked()
        XCTAssertEqual(state.handle(.becameUnmuted), .reassertMute)
        state.isLocked = false
        XCTAssertEqual(state.handle(.becameUnmuted), .doNothing)
    }

    // MARK: - Engaging the lock

    func testEngagingTheLockOnALiveMicMutesIt() {
        XCTAssertEqual(
            PrivacyGuardState.actionOnLockEngaged(currentlyMuted: false), .reassertMute)
    }

    func testEngagingTheLockOnAnAlreadyMutedMicDoesNothing() {
        // No point re-muting something already muted, and doing so would emit a change to chase.
        XCTAssertEqual(
            PrivacyGuardState.actionOnLockEngaged(currentlyMuted: true), .doNothing)
    }
}
