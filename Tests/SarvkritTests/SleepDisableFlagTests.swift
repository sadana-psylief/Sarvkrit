import XCTest
@testable import Sarvkrit

/// The enable script runs as **root**, and the watchdog inside it is what restores normal sleep
/// after a crash. "Looks about right" isn't good enough for a root shell command, so its shape is
/// asserted directly.
final class SleepDisableFlagTests: XCTestCase {

    private func enableScript(pid: Int32 = 4242, seconds: Int = 1_800) -> String {
        SleepDisableFlag.enableScript(pid: pid, watchdogSeconds: seconds)
    }

    func testTheScriptSetsTheFlag() {
        XCTAssertTrue(enableScript().contains("pmset -a disablesleep 1"))
    }

    func testTheWatchdogWatchesOurActualProcess() {
        // If it watched the wrong PID it would either never clean up, or clean up immediately.
        XCTAssertTrue(enableScript(pid: 9_876).contains("kill -0 9876"))
    }

    func testTheWatchdogClearsTheFlagWhenItFinishes() {
        // The whole point: after a crash this line is what gives the Mac its sleep back.
        XCTAssertTrue(enableScript().contains("pmset -a disablesleep 0"))
    }

    func testTheWatchdogHonoursTheChosenDeadline() {
        XCTAssertTrue(enableScript(seconds: 1_800).contains("-lt 1800"))
        XCTAssertTrue(enableScript(seconds: 43_200).contains("-lt 43200"))
    }

    func testTheWatchdogIsTaggedSoItCanBeReplaced() {
        // Repeat activations must replace the pending watchdog, not stack them up.
        let script = enableScript()
        XCTAssertTrue(script.contains(SleepDisableFlag.watchdogTag))
        XCTAssertTrue(script.contains("pkill -f '\(SleepDisableFlag.watchdogTag)'"))
    }

    func testTheWatchdogIsDetachedSoItSurvivesUs() {
        // Without nohup and backgrounding it would die with the app — precisely when it's needed.
        let script = enableScript()
        XCTAssertTrue(script.contains("nohup"))
        XCTAssertTrue(script.contains("&"))
    }

    func testTheDisableScriptAlsoStopsThePendingWatchdog() {
        // Otherwise a watchdog would fire later and clear a flag the user had since re-enabled.
        let script = SleepDisableFlag.disableScript()
        XCTAssertTrue(script.contains("pmset -a disablesleep 0"))
        XCTAssertTrue(script.contains("pkill -f '\(SleepDisableFlag.watchdogTag)'"))
    }

    func testScriptsUseAbsolutePathsForPmset() {
        // A root shell shouldn't be resolving commands through an inherited PATH.
        XCTAssertTrue(enableScript().contains("/usr/bin/pmset"))
        XCTAssertTrue(SleepDisableFlag.disableScript().contains("/usr/bin/pmset"))
    }

    func testTheIndefiniteCeilingIsWhatTheWatchdogGets() {
        // "Indefinite" still gets a ceiling — a bag is not a working session.
        let script = enableScript(seconds: Int(KeepAwakeDuration.indefinite.watchdogSeconds))
        XCTAssertTrue(script.contains("-lt 43200"))
    }
}
