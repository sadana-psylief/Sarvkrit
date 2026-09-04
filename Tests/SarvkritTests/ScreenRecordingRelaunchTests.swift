import XCTest
@testable import Sarvkrit

/// The stale-grant rule, which is otherwise only reproducible by revoking a real TCC grant and
/// relaunching — not something to verify by hand on every change.
final class ScreenRecordingRelaunchTests: XCTestCase {

    func testGrantedButNoDisplaysIsAStaleGrant() {
        // The contradiction that means "granted after this process launched": macOS says yes,
        // ScreenCaptureKit hands back nothing.
        XCTAssertTrue(ScreenRecordingRelaunch.looksLikeStaleGrant(
            preflightGranted: true, capturedDisplayCount: 0))
    }

    func testAWorkingCaptureIsNeverStale() {
        XCTAssertFalse(ScreenRecordingRelaunch.looksLikeStaleGrant(
            preflightGranted: true, capturedDisplayCount: 1))
        XCTAssertFalse(ScreenRecordingRelaunch.looksLikeStaleGrant(
            preflightGranted: true, capturedDisplayCount: 3))
    }

    func testAnUngrantedStateIsNotStale() {
        // Ordinary "you haven't granted this yet" — the banner covers it, and offering a relaunch
        // would send the user round a loop that cannot help.
        XCTAssertFalse(ScreenRecordingRelaunch.looksLikeStaleGrant(
            preflightGranted: false, capturedDisplayCount: 0))
    }
}
