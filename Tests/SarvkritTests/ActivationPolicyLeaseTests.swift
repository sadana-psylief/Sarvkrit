import XCTest
@testable import Sarvkrit

/// The counting itself, which is the part that has to be right.
///
/// Asserting on `NSApp.setActivationPolicy` would mean changing the real app's policy during a
/// test run, so these check the count and the transitions it reports instead.
@MainActor
final class ActivationPolicyLeaseTests: XCTestCase {

    /// A fresh instance per test — the shared one belongs to the running app.
    private func makeLease() -> ActivationPolicyLease { ActivationPolicyLease() }

    func testTheFirstAcquireIsTheOneThatRaisesThePolicy() {
        let lease = makeLease()
        XCTAssertTrue(lease.acquire())
        XCTAssertFalse(lease.acquire(), "a second window doesn't raise it again")
        XCTAssertEqual(lease.count, 2)
    }

    func testTheLastReleaseIsTheOneThatLowersIt() {
        // The bug this type exists for: closing one of two windows must not drop the app back to
        // .accessory while the other is still open and expecting to take key focus.
        let lease = makeLease()
        lease.acquire()
        lease.acquire()
        lease.release()
        XCTAssertEqual(lease.count, 1, "still held by the remaining window")
        lease.release()
        XCTAssertEqual(lease.count, 0)
    }

    func testAnOverReleaseCannotDriveTheCountNegative() {
        // A window controller that closes twice would otherwise leave the count at -1, and the
        // *next* acquire would fail to raise the policy at all.
        let lease = makeLease()
        lease.release()
        lease.release()
        XCTAssertEqual(lease.count, 0)
        XCTAssertTrue(lease.acquire(), "the next acquire must still work")
    }

    func testAcquireAndReleasePair() {
        let lease = makeLease()
        for _ in 0..<5 { lease.acquire() }
        for _ in 0..<5 { lease.release() }
        XCTAssertEqual(lease.count, 0)
    }
}
