import XCTest
@testable import Sarvkrit

/// The two cases these exist for are both live in this repo right now: `MARKETING_VERSION` is
/// `1.1` while the next tag is `v1.1.0` (2-vs-3 components), and a tenth patch release would
/// compare as older than the ninth under string ordering.
final class AppVersionTests: XCTestCase {
    private func v(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> AppVersion {
        guard let parsed = AppVersion(s) else {
            XCTFail("expected '\(s)' to parse", file: file, line: line)
            return AppVersion("0.0")!
        }
        return parsed
    }

    func testPatchReleaseIsNewerThanTheLineItPatches() {
        XCTAssertLessThan(v("1.0"), v("1.0.1"))
        XCTAssertGreaterThan(v("1.0.1"), v("1.0"))
    }

    /// The whole reason this type exists instead of `<` on String.
    func testTenthPatchIsNewerThanNinth() {
        XCTAssertGreaterThan(v("1.10"), v("1.9"))
        XCTAssertGreaterThan(v("1.0.10"), v("1.0.9"))
        XCTAssertGreaterThan(v("2.0"), v("1.99"))
    }

    /// Today's state: the running app says `1.1`, the git tag says `v1.0`.
    func testMissingComponentsAreZero() {
        XCTAssertEqual(v("1.0"), v("1.0.0"))
        XCTAssertEqual(v("1.0"), v("v1.0"))
        XCTAssertFalse(v("1.0") < v("1.0.0"))
        XCTAssertFalse(v("1.0.0") < v("1.0"))
    }

    func testTagPrefixIsStrippedFromEitherSide() {
        XCTAssertEqual(v("v1.2.3").description, "1.2.3")
        XCTAssertEqual(v("V1.2.3"), v("1.2.3"))
        XCTAssertEqual(v(" v1.2.3 \n"), v("1.2.3"))
    }

    /// Anything unparseable must be nil, not a guess. A nil version means the app stays silent,
    /// which is the right failure: a wrong "update available" is worse than none.
    func testGarbageIsRejected() {
        for bad in ["", "v", "latest", "1", "1.0-beta", "1..0", "1.0.", ".1.0", "1.0.0.0.0",
                    "one.two", "1.0+1", "-1.0", "1.0 (1)", "١.٠"] {
            XCTAssertNil(AppVersion(bad), "expected '\(bad)' to be rejected")
        }
    }

    /// A dev build between releases is ahead of the latest published version. That must read as
    /// "nothing to do", never as an update.
    func testRunningAheadOfTheLatestReleaseIsNotAnUpdate() {
        XCTAssertGreaterThan(v("1.1"), v("1.0.9"))
        XCTAssertFalse(v("1.1") < v("1.0.9"))
    }

    /// The exact pairs the 1.1.0 release creates, pinned because getting either wrong shows
    /// every 1.1.0 user a permanent "update available" banner for a version they already have.
    /// `MARKETING_VERSION` is two components today and three after the bump; the tag is three.
    func testTheOneOneZeroReleaseReadsAsUpToDate() {
        XCTAssertEqual(v("1.1"), v("v1.1.0"))
        XCTAssertEqual(v("1.1.0"), v("v1.1.0"))
        XCTAssertFalse(v("1.1") < v("v1.1.0"))
        XCTAssertFalse(v("1.1.0") < v("v1.1.0"))
        // And the release it supersedes still reads as older, from either shape.
        XCTAssertGreaterThan(v("1.1"), v("v1.0"))
        XCTAssertGreaterThan(v("1.1.0"), v("v1.0"))
    }

    func testCurrentReadsTheShortVersionString() {
        // The test bundle is hosted inside Sarvkrit.app, so this is the real app's version.
        let bundle = Bundle(for: type(of: self))
        if bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") is String {
            XCTAssertNotNil(AppVersion.current(bundle: bundle))
        }
    }
}
