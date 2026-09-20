import XCTest
@testable import Sarvkrit

/// What the feature does once it is actually driving the fans.
///
/// No test here opens a socket, runs a privileged script or writes an SMC key: the helper is a
/// spy and so is the authorisation dialog, the same seam `KeepAwakeTurnOffTests` uses. The point
/// is the decisions, and those must be reachable without root.
@MainActor
final class FanControlDrivingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "fanControl.driving.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Records what it was asked to do instead of talking to a root process.
    private final class HelperSpy: FanCommandSink {
        var onLost: (() -> Void)?
        var isConnected = false
        var started = 0
        var stopped = 0
        var sent: [FanWire.Command] = []
        var startSucceeds = true

        func start() -> Bool {
            started += 1
            isConnected = startSucceeds
            return startSucceeds
        }
        func send(_ command: FanWire.Command) { sent.append(command) }

        /// Faithful to the protocol's contract: `stop()` hands the fans back before closing, and
        /// `FanHelperSession` does exactly this. A spy that just closed would let a feature that
        /// forgot to release pass.
        func stop() {
            stopped += 1
            if isConnected { sent.append(.auto); sent.append(.quit) }
            isConnected = false
        }

        var speeds: [Int] { sent.compactMap { if case let .set(p) = $0 { return p } else { return nil } } }
        var releases: Int { sent.filter { $0 == .auto }.count }
    }

    private final class Bench {
        let helper = HelperSpy()
        var celsius: Double? = 50
        /// What `F0Md` reads. Starts absent, so the ordinary path is unaffected.
        var forcedAfterWake: Bool?
        var privilegedScripts: [String] = []
        var privilegedSucceeds = true

        func feature(_ defaults: UserDefaults) -> FanControlFeature {
            FanControlFeature(
                defaults: defaults,
                makeSampler: { [unowned self] in FanSampler(read: { [unowned self] key in
                    var keys: [String: Double] = [
                        "FNum": 2, "F0Ac": 2400, "F0Mn": 2317, "F0Mx": 6800,
                        "F1Ac": 2400, "F1Mn": 2317, "F1Mx": 6800]
                    if let forced = self.forcedAfterWake {
                        keys["F0Md"] = forced ? 1 : 0
                        keys["F1Md"] = forced ? 1 : 0
                    }
                    return keys[key.description]
                }) },
                makeSink: { [unowned self] _ in self.helper },
                readTemperature: { [unowned self] in self.celsius },
                runPrivileged: { [unowned self] script in
                    self.privilegedScripts.append(script)
                    return self.privilegedSucceeds
                })
        }
    }

    private func settle() {
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: - Taking control

    func testChoosingAManualSpeedAsksForTheHelperOnce() {
        let bench = Bench()
        let feature = bench.feature(defaults)
        feature.activate()
        settle()

        feature.mode = .manual(percent: 70)
        settle()

        XCTAssertEqual(bench.helper.started, 1)
        XCTAssertEqual(bench.helper.speeds.last, 70)
        feature.deactivate()
    }

    /// A cancelled password dialog must leave nothing half-on. The user said no.
    func testCancellingThePasswordPromptLeavesTheFansAlone() {
        let bench = Bench()
        bench.helper.startSucceeds = false
        let feature = bench.feature(defaults)
        feature.activate()
        settle()

        feature.mode = .manual(percent: 70)
        settle()

        XCTAssertEqual(feature.mode, .monitor, "the mode must fall back when authorisation fails")
        XCTAssertTrue(bench.helper.speeds.isEmpty)
        feature.deactivate()
    }

    // MARK: - Letting go

    /// The helper is already root and already connected, so switching off costs nothing. A
    /// password prompt to *stop* doing something would be indefensible.
    func testSwitchingOffCostsNoPasswordPrompt() {
        let bench = Bench()
        let feature = bench.feature(defaults)
        feature.activate()
        settle()
        feature.mode = .manual(percent: 70)
        settle()
        let scriptsWhileRunning = bench.privilegedScripts.count

        feature.deactivate()

        XCTAssertEqual(bench.privilegedScripts.count, scriptsWhileRunning,
                       "turning it off must not ask for a password")
        XCTAssertEqual(bench.helper.stopped, 1)
    }

    func testGoingBackToWatchingReleasesTheFans() {
        let bench = Bench()
        let feature = bench.feature(defaults)
        feature.activate()
        settle()
        feature.mode = .manual(percent: 70)
        settle()

        feature.mode = .monitor
        settle()

        XCTAssertGreaterThan(bench.helper.releases, 0)
        feature.deactivate()
    }

    // MARK: - The ceiling

    /// The rule that outranks the user, end to end rather than only in the pure policy.
    func testGettingTooHotHandsTheFansBackWithoutBeingAsked() {
        let bench = Bench()
        let feature = bench.feature(defaults)
        feature.activate()
        settle()
        feature.mode = .manual(percent: 30)
        settle()

        bench.celsius = 97
        feature.tick()
        settle()

        XCTAssertGreaterThan(bench.helper.releases, 0, "the ceiling must release the fans")
        feature.deactivate()
    }

    // MARK: - The ramp

    func testTheRampTakesHoldOnceTheMacIsHotEnough() {
        let bench = Bench()
        bench.celsius = 60
        let feature = bench.feature(defaults)
        feature.activate()
        settle()
        feature.mode = .automatic(FanCurve(thresholdCelsius: 75, targetPercent: 70,
                                           hysteresisCelsius: 4))
        settle()
        XCTAssertTrue(bench.helper.speeds.isEmpty, "nothing to do at 60 °C")

        bench.celsius = 80
        feature.tick()
        settle()

        XCTAssertEqual(bench.helper.speeds.last, 70)
        feature.deactivate()
    }

    // MARK: - When the helper dies

    /// A crash loop that re-fires a password dialog every few seconds is indistinguishable from
    /// malware. It has to be a stated condition instead.
    func testAHelperThatDiesIsReportedRatherThanSilentlyRestarted() {
        let bench = Bench()
        let feature = bench.feature(defaults)
        feature.activate()
        settle()
        feature.mode = .manual(percent: 70)
        settle()
        let startsBefore = bench.helper.started

        bench.helper.onLost?()
        settle()

        XCTAssertTrue(feature.controlWasLost)
        XCTAssertEqual(bench.helper.started, startsBefore, "it must not re-prompt on its own")
        feature.deactivate()
    }

    // MARK: - Persistence

    func testTheChosenModeSurvivesARestart() {
        let bench = Bench()
        let first = bench.feature(defaults)
        first.activate()
        settle()
        first.mode = .manual(percent: 65)
        settle()
        first.deactivate()

        XCTAssertEqual(Bench().feature(defaults).mode, .manual(percent: 65))
    }

    /// The actual safety claim behind persisting the mode: a Mac that boots must not spend the
    /// user's password on a setting from last week, with no prompt they asked for and no
    /// explanation. Restoring a mode is the user picking it again.
    func testARestoredModeDoesNotStartDrivingByItself() {
        let bench = Bench()
        let first = bench.feature(defaults)
        first.activate()
        settle()
        first.mode = .manual(percent: 65)
        settle()
        first.deactivate()

        let next = Bench()
        let second = next.feature(defaults)
        second.activate()
        settle()

        XCTAssertEqual(next.helper.started, 0, "a restored mode must not ask for a password")
        XCTAssertTrue(next.helper.sent.isEmpty)
        second.deactivate()
    }

    /// The SMC can drop a forced fan mode across a sleep cycle. Without this the fans quietly go
    /// back to macOS on wake while the panel goes on claiming Sarvkrit is holding them.
    func testWakingUpTakesBackAHoldTheMacDropped() {
        let bench = Bench()
        let feature = bench.feature(defaults)
        feature.activate()
        settle()
        feature.mode = .manual(percent: 70)
        settle()
        let sentBefore = bench.helper.speeds.count

        bench.forcedAfterWake = false      // the SMC let go while the Mac slept
        feature.systemDidWake()
        settle()

        XCTAssertGreaterThan(bench.helper.speeds.count, sentBefore,
                             "the hold must be re-asserted after a wake that dropped it")
        feature.deactivate()
    }

    /// A fan still held after a wake needs nothing doing. Re-sending regardless would be a write
    /// to firmware every lid-open for no reason.
    func testWakingUpLeavesAHoldTheMacKept() {
        let bench = Bench()
        let feature = bench.feature(defaults)
        feature.activate()
        settle()
        feature.mode = .manual(percent: 70)
        settle()
        let sentBefore = bench.helper.speeds.count

        bench.forcedAfterWake = true       // still ours
        feature.systemDidWake()
        settle()

        XCTAssertEqual(bench.helper.speeds.count, sentBefore)
        feature.deactivate()
    }
}
