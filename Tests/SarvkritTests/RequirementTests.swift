import XCTest
@testable import Sarvkrit

/// Pins the `Requirement` contract the permission UI renders from.
///
/// The UI used to hardcode Accessibility in three places, so a second queryable grant would have
/// shown the wrong title and opened the wrong settings pane. These assert the data is complete for
/// *every* case, so adding a third grant fails here rather than in a screenshot someone notices later.
final class RequirementTests: XCTestCase {

    func testEveryRequirementHasUserFacingText() {
        for requirement in Requirement.allCases {
            XCTAssertFalse(requirement.title.isEmpty, "\(requirement) has no title")
            XCTAssertFalse(requirement.explanation.isEmpty, "\(requirement) has no explanation")
        }
    }

    func testEveryRequirementOpensASystemSettingsPane() {
        for requirement in Requirement.allCases {
            let url = requirement.settingsURL
            XCTAssertEqual(url.scheme, "x-apple.systempreferences", "\(requirement): wrong scheme")
            XCTAssertFalse(url.absoluteString.hasSuffix("?"), "\(requirement): no pane anchor")
        }
    }

    func testEveryRequirementPointsAtADifferentPane() {
        // Two requirements sharing a URL means one of them sends the user somewhere useless.
        let urls = Requirement.allCases.map(\.settingsURL.absoluteString)
        XCTAssertEqual(Set(urls).count, urls.count, "two requirements share a settings URL")
    }

    func testOnlyAudioCaptureIsUnqueryable() {
        // The whole gating model in AppState.sync() turns on this: a requirement we can't ask
        // about must never block a feature, because the answer would always be "no".
        XCTAssertTrue(Requirement.accessibility.isQueryable)
        XCTAssertTrue(Requirement.screenRecording.isQueryable)
        XCTAssertFalse(Requirement.audioCapture.isQueryable)
    }

    func testSortOrderIsATotalOrderOverAllCases() {
        let orders = Requirement.allCases.map(\.sortOrder)
        XCTAssertEqual(Set(orders).count, orders.count, "two requirements share a sort order")
        XCTAssertEqual(orders.sorted(), Array(0..<Requirement.allCases.count))
    }
}
