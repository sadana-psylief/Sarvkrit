import XCTest
@testable import Sarvkrit

/// Turning Keep Awake off has to put system sleep back.
///
/// 1.1.0 shipped without this: the lid-closed option set `SleepDisabled` machine-wide and no
/// user-initiated *off* path ever cleared it, so a Mac stayed unable to sleep until the user found
/// a banner button — or for twelve hours. `KeepAwakeStateTests` covers the pure truth table and
/// `SleepDisableFlagTests` covers the shape of the root scripts; neither touched the toggle path,
/// which is exactly where the bug lived. These tests are that path.
///
/// `@MainActor` because they drive `AppState.setEnabled`, as `AppStateTests` does.
@MainActor
final class KeepAwakeTurnOffTests: XCTestCase {

    /// Records the scripts it is handed instead of running them, so the whole suite stays off
    /// `NSAppleScript` and never writes a real `pmset` setting.
    private final class PrivilegedSpy {
        private(set) var scripts: [String] = []
        var succeeds = true

        func run(_ script: String) -> Bool {
            scripts.append(script)
            return succeeds
        }

        /// Matched against the whole script, not a substring: the *enable* script also contains
        /// "disablesleep 0" — that is its watchdog's cleanup line — so a substring test here
        /// reports success the moment the option is switched on and can never fail.
        var clearedSleep: Bool { scripts.contains(SleepDisableFlag.disableScript()) }
        var disabledSleep: Bool { scripts.contains { $0.contains("pmset -a disablesleep 1") } }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "keepAwake.turnOff.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeFeature(_ spy: PrivilegedSpy) -> KeepAwakeFeature {
        KeepAwakeFeature(defaults: defaults, runPrivileged: spy.run)
    }

    /// Puts the feature in the state the bug report describes: running, lid-closed on, flag ours.
    private func makeRunningWithLidClosed(_ spy: PrivilegedSpy) -> KeepAwakeFeature {
        let feature = makeFeature(spy)
        feature.activate()
        feature.lidClosed = true
        XCTAssertTrue(spy.disabledSleep, "precondition: turning it on should disable sleep")
        XCTAssertTrue(defaults.bool(forKey: KeepAwakeFeature.weSetFlagKey),
                      "precondition: the flag should be recorded as ours")
        return feature
    }

    // MARK: - The bug

    func testTurningLidClosedOffRestoresSleep() {
        let spy = PrivilegedSpy()
        let feature = makeRunningWithLidClosed(spy)

        feature.lidClosed = false

        XCTAssertTrue(spy.clearedSleep,
                      "turning the lid-closed option off must clear SleepDisabled, not leave the Mac unable to sleep")
        XCTAssertFalse(defaults.bool(forKey: KeepAwakeFeature.weSetFlagKey),
                       "once cleared we no longer own the flag")
    }

    func testTurningKeepAwakeOffRestoresSleep() throws {
        let spy = PrivilegedSpy()
        let feature = makeRunningWithLidClosed(spy)

        // Through AppState, because the master toggle is a generic feature binding — the wiring is
        // as much the fix as the method it calls.
        let state = AppState(
            features: [feature],
            store: FeatureStore(defaults: defaults),
            permissions: PermissionsManager(),
            defaults: defaults
        )
        state.setEnabled(feature, true)
        state.setEnabled(feature, false)

        XCTAssertTrue(spy.clearedSleep,
                      "turning Keep Awake off must clear SleepDisabled; the watchdog only fires when the app exits")
    }

    // MARK: - Invariants the fix must not break

    func testAFlagWeDidNotSetIsLeftAlone() {
        let spy = PrivilegedSpy()
        // Lid-closed on, but never recorded as ours — somebody disabled sleep by hand.
        defaults.set(true, forKey: KeepAwakeFeature.lidClosedKey)
        let feature = makeFeature(spy)

        feature.lidClosed = false

        XCTAssertTrue(spy.scripts.isEmpty,
                      "a flag somebody else set is not ours to clear, and clearing costs a password")
    }

    func testActivatingWithLidClosedOffAsksForNothing() {
        let spy = PrivilegedSpy()
        let feature = makeFeature(spy)

        feature.activate()

        XCTAssertTrue(spy.scripts.isEmpty,
                      "launch must not fire an unexplained password dialog — that is what the stranded banner is for")
    }

    func testADeclinedPromptKeepsOwnershipSoTheBannerStillCatchesIt() {
        let spy = PrivilegedSpy()
        let feature = makeRunningWithLidClosed(spy)
        spy.succeeds = false

        feature.lidClosed = false

        XCTAssertTrue(spy.clearedSleep, "it should still have tried")
        XCTAssertTrue(defaults.bool(forKey: KeepAwakeFeature.weSetFlagKey),
                      "the flag is still set and still ours, so the pane must keep offering to restore it")
    }
}
