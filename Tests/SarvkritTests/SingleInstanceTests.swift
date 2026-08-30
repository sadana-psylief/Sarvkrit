import XCTest
@testable import Sarvkrit

final class SingleInstanceTests: XCTestCase {
    private let ownPID: pid_t = 4242

    func testYieldsWhenAnotherInstanceIsRunning() {
        XCTAssertTrue(SingleInstance.shouldYield(otherInstancePIDs: [99], ownPID: ownPID))
    }

    func testDoesNotYieldWhenTheOnlyInstanceIsUs() {
        // The failure that matters. `runningApplications(withBundleIdentifier:)` usually
        // includes the calling process, so a naive `count > 1` — or `!isEmpty` — makes the app
        // decide it's a duplicate of itself and exit on every single launch.
        XCTAssertFalse(SingleInstance.shouldYield(otherInstancePIDs: [ownPID], ownPID: ownPID))
    }

    func testDoesNotYieldWhenNothingIsRunning() {
        // The list can also come back empty this early in launch, before our own process is
        // registered. Both shapes have to mean "we're the only one".
        XCTAssertFalse(SingleInstance.shouldYield(otherInstancePIDs: [], ownPID: ownPID))
    }

    func testYieldsWhenListContainsUsAndAnother() {
        XCTAssertTrue(SingleInstance.shouldYield(otherInstancePIDs: [ownPID, 99], ownPID: ownPID))
    }

    func testNeverYieldsWhenHostingTests() {
        // The test bundle runs inside Sarvkrit.app, so this exact code path executes during
        // `make test`. Without the exemption, a developer with the app open would see the whole
        // suite fail to launch — and the cause would be invisible.
        XCTAssertFalse(SingleInstance.shouldYield(
            otherInstancePIDs: [99, 100], ownPID: ownPID, isTestHost: true))
    }

    func testWeAreCurrentlyRunningAsATestHost() {
        // Proves the environment probe that feeds `isTestHost` actually works, rather than
        // silently returning false and leaving the exemption above dead.
        XCTAssertTrue(SingleInstance.isRunningTests)
    }

    func testNotificationNameIsScopedToTheBundle() {
        // Cross-process and therefore global: an unscoped name could collide with another app's.
        XCTAssertTrue(AppIdentity.showWindowNotification.rawValue.hasPrefix(AppIdentity.bundleID))
        XCTAssertTrue(AppIdentity.showWindowNotification.rawValue.hasSuffix(".showWindow"))
    }
}
