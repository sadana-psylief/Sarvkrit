import ApplicationServices
import XCTest
@testable import Sarvkrit

final class CloseButtonHitTestTests: XCTestCase {
    private let own = "ai.psylief.sarvkrit"

    private func target(
        role: String? = kAXButtonRole as String,
        subrole: String? = kAXCloseButtonSubrole as String,
        bundleID: String? = "com.apple.TextEdit",
        isRegularApp: Bool = true
    ) -> CloseButtonHitTest.Target {
        CloseButtonHitTest.Target(
            role: role, subrole: subrole, bundleID: bundleID, isRegularApp: isRegularApp
        )
    }

    func testCloseButtonInARegularAppIsAccepted() {
        XCTAssertTrue(CloseButtonHitTest.isCloseButton(target(), ownBundleID: own))
    }

    func testMinimiseAndZoomButtonsAreRejected() {
        // Same role, different subrole — only the red one should ever lead to a quit.
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(
            target(subrole: kAXMinimizeButtonSubrole as String), ownBundleID: own))
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(
            target(subrole: kAXZoomButtonSubrole as String), ownBundleID: own))
    }

    func testNonButtonElementsAreRejected() {
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(
            target(role: kAXWindowRole as String, subrole: nil), ownBundleID: own))
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(
            target(role: nil, subrole: nil), ownBundleID: own))
    }

    func testFinderIsExcluded() {
        // Quitting Finder takes the desktop and every file operation with it.
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(
            target(bundleID: "com.apple.finder"), ownBundleID: own))
    }

    func testSarvkritItselfIsExcluded() {
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(target(bundleID: own), ownBundleID: own))
    }

    func testBackgroundAgentsAreExcluded() {
        // Terminating a menu bar agent because it owned a stray panel would be hostile.
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(
            target(isRegularApp: false), ownBundleID: own))
    }

    func testUnidentifiedAppIsExcluded() {
        XCTAssertFalse(CloseButtonHitTest.isCloseButton(target(bundleID: nil), ownBundleID: own))
    }

    // MARK: - Termination decision

    func testTerminatesOnlyWhenNoWindowsRemain() {
        XCTAssertTrue(CloseButtonHitTest.shouldTerminate(windowCount: 0))
        XCTAssertFalse(CloseButtonHitTest.shouldTerminate(windowCount: 1))
        XCTAssertFalse(CloseButtonHitTest.shouldTerminate(windowCount: 5))
    }

    func testUnknownWindowCountDoesNotTerminate() {
        // nil means the app couldn't be asked — already gone, or briefly busy. Treating that
        // as "zero windows" would kill apps for being slow.
        XCTAssertFalse(CloseButtonHitTest.shouldTerminate(windowCount: nil))
    }
}
