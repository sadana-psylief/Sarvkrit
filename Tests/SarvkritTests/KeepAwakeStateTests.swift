import XCTest
@testable import Sarvkrit

/// `SleepDisabled` belongs to the whole machine, survives reboots, and needs a password to change.
/// Getting this wrong either leaves a laptop unable to sleep in a bag, or silently undoes a setting
/// somebody made deliberately. Neither failure announces itself, so the decision is tested in full.
final class KeepAwakeStateTests: XCTestCase {

    private func action(weSetIt: Bool, wants: Bool, flagOn: Bool) -> KeepAwakeState.Action {
        KeepAwakeState.action(for: .init(weSetIt: weSetIt, wantsLidClosed: wants, flagIsOn: flagOn))
    }

    // MARK: - Every combination

    func testTheWholeTruthTable() {
        // Deliberately exhaustive: eight rows, each with a reason.
        XCTAssertEqual(action(weSetIt: false, wants: true, flagOn: false), .set,
                       "first activation should set it")
        XCTAssertEqual(action(weSetIt: true, wants: true, flagOn: false), .set,
                       "the watchdog cleared it while the toggle stayed on — re-set it")
        XCTAssertEqual(action(weSetIt: true, wants: true, flagOn: true), .doNothing,
                       "already in the state the user asked for")
        XCTAssertEqual(action(weSetIt: false, wants: true, flagOn: true), .doNothing,
                       "already on, whoever set it")
        XCTAssertEqual(action(weSetIt: true, wants: false, flagOn: true), .offerToRestore,
                       "ours and stranded by a reboot — surface it, don't ambush with a prompt")
        XCTAssertEqual(action(weSetIt: false, wants: false, flagOn: true), .doNothing,
                       "not ours — somebody disabled sleep on purpose")
        XCTAssertEqual(action(weSetIt: true, wants: false, flagOn: false), .doNothing)
        XCTAssertEqual(action(weSetIt: false, wants: false, flagOn: false), .doNothing)
    }

    func testWeNeverClearAFlagWeDidNotSet() {
        // The rule that protects someone who ran `sudo pmset -a disablesleep 1` by hand.
        for wants in [true, false] {
            XCTAssertNotEqual(action(weSetIt: false, wants: wants, flagOn: true), .offerToRestore)
        }
    }

    func testAStrandedFlagIsNeverClearedSilently() {
        // Clearing costs a password. Doing it unasked at launch would be worse than the problem.
        let stranded = KeepAwakeState.Situation(weSetIt: true, wantsLidClosed: false, flagIsOn: true)
        XCTAssertEqual(KeepAwakeState.action(for: stranded), .offerToRestore)
        XCTAssertTrue(KeepAwakeState.showsStrandedWarning(for: stranded))
    }

    func testNoWarningWhenNothingIsStranded() {
        XCTAssertFalse(KeepAwakeState.showsStrandedWarning(
            for: .init(weSetIt: true, wantsLidClosed: true, flagIsOn: true)))
        XCTAssertFalse(KeepAwakeState.showsStrandedWarning(
            for: .init(weSetIt: false, wantsLidClosed: false, flagIsOn: true)))
    }

    // MARK: - Reading the system's answer

    func testParsesSleepDisabledFromRealPmsetOutput() {
        let output = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatemode        3
        """
        XCTAssertEqual(KeepAwakeState.parseSleepDisabled(output), true)
    }

    func testParsesTheDisabledCase() {
        XCTAssertEqual(KeepAwakeState.parseSleepDisabled(" SleepDisabled\t\t0"), false)
    }

    func testAbsentKeyIsNilNotFalse() {
        // The distinction matters: "not listed" must not read as "sleep is enabled", or we'd think
        // a flag we set had vanished and re-prompt for the password.
        let output = """
        Currently in use:
         standby              1
         hibernatemode        3
        """
        XCTAssertNil(KeepAwakeState.parseSleepDisabled(output))
        XCTAssertNil(KeepAwakeState.parseSleepDisabled(""))
    }

    func testASimilarlyNamedKeyIsNotMistakenForIt() {
        XCTAssertNil(KeepAwakeState.parseSleepDisabled(" SleepDisabledByUser  1"))
    }

    // MARK: - Durations

    func testIndefiniteHasNoAssertionDeadlineButStillHasAWatchdogCeiling() {
        // "Indefinite" means for a working session, not until the battery is flat.
        XCTAssertNil(KeepAwakeDuration.indefinite.seconds)
        XCTAssertEqual(KeepAwakeDuration.indefinite.watchdogSeconds, KeepAwakeDuration.watchdogCeiling)
    }

    func testFiniteDurationsDriveBothTheTimerAndTheWatchdog() {
        XCTAssertEqual(KeepAwakeDuration.thirtyMinutes.seconds, 1_800)
        XCTAssertEqual(KeepAwakeDuration.thirtyMinutes.watchdogSeconds, 1_800)
        XCTAssertEqual(KeepAwakeDuration.fourHours.watchdogSeconds, 14_400)
    }

    func testNoDurationEverExceedsTheCeiling() {
        for duration in KeepAwakeDuration.allCases {
            XCTAssertLessThanOrEqual(duration.watchdogSeconds, KeepAwakeDuration.watchdogCeiling)
        }
    }

    func testEveryDurationIsLabelled() {
        for duration in KeepAwakeDuration.allCases {
            XCTAssertFalse(duration.title.isEmpty)
        }
    }
}
