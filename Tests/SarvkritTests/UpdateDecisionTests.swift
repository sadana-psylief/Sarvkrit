import Combine
import XCTest
@testable import Sarvkrit

/// The whole user-visible policy is one pure function. These are the cases it has to get right.
final class UpdateDecisionTests: XCTestCase {
    private func release(_ tag: String) -> LatestRelease {
        LatestRelease(tagName: tag, name: nil, body: nil, htmlURL: nil, publishedAt: nil)
    }

    private func decide(current: String?, latest: String?, skipped: String? = nil) -> UpdateChecker.State {
        UpdateChecker.decide(
            current: current.flatMap(AppVersion.init),
            latest: latest.map(release),
            skipped: skipped.flatMap(AppVersion.init))
    }

    func testNewerReleaseIsOffered() {
        XCTAssertEqual(decide(current: "1.0", latest: "v1.0.1"), .available(release("v1.0.1")))
        XCTAssertEqual(decide(current: "1.9", latest: "v1.10"), .available(release("v1.10")))
    }

    func testSameVersionIsUpToDate() {
        XCTAssertEqual(decide(current: "1.0", latest: "v1.0"), .upToDate)
        XCTAssertEqual(decide(current: "1.0", latest: "v1.0.0"), .upToDate)
    }

    /// Every build between releases is ahead of the latest published one. It must read as
    /// "nothing to do" — an app that offers to downgrade you is worse than one that says nothing.
    func testRunningAheadOfTheReleaseIsUpToDate() {
        XCTAssertEqual(decide(current: "1.1", latest: "v1.0"), .upToDate)
        XCTAssertEqual(decide(current: "2.0", latest: "v1.99.99"), .upToDate)
    }

    /// Silence, not a guess, whenever anything is missing or unreadable.
    func testUnknownWhenAnythingIsMissing() {
        XCTAssertEqual(decide(current: "1.0", latest: nil), .unknown)
        XCTAssertEqual(decide(current: nil, latest: "v1.1"), .unknown)
        XCTAssertEqual(decide(current: "1.0", latest: "latest"), .unknown)
        XCTAssertEqual(decide(current: "1.0", latest: "1.0-beta"), .unknown)
    }

    func testSkippedVersionIsNotOffered() {
        XCTAssertEqual(decide(current: "1.0", latest: "v1.1", skipped: "1.1"), .upToDate)
    }

    /// Skipping one version must not silence every future one.
    func testAVersionNewerThanTheSkippedOneIsStillOffered() {
        XCTAssertEqual(decide(current: "1.0", latest: "v1.2", skipped: "1.1"), .available(release("v1.2")))
    }

    func testSkippingAnOlderVersionChangesNothing() {
        XCTAssertEqual(decide(current: "1.0", latest: "v1.1", skipped: "1.0.5"), .available(release("v1.1")))
    }
}

final class UpdateCheckerTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-checker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "ai.psylief.sarvkrit.updates.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func writeFeed(_ tag: String) throws {
        try Data(#"{"tag_name":"\#(tag)"}"#.utf8)
            .write(to: directory.appendingPathComponent(UpdateFeedStore.feedFileName))
    }

    private func makeChecker(current: String = "1.0") -> UpdateChecker {
        UpdateChecker(
            store: UpdateFeedStore(directory: directory),
            currentVersion: AppVersion(current),
            defaults: defaults)
    }

    func testReadsTheFeedOnInit() throws {
        try writeFeed("v1.1")
        XCTAssertEqual(makeChecker().state, .available(
            LatestRelease(tagName: "v1.1", name: nil, body: nil, htmlURL: nil, publishedAt: nil)))
    }

    func testNoFeedMeansUnknownAndStale() {
        let checker = makeChecker()
        XCTAssertEqual(checker.state, .unknown)
        XCTAssertNil(checker.lastChecked)
        XCTAssertTrue(checker.isStale)
    }

    func testAFreshFeedIsNotStale() throws {
        try writeFeed("v1.0")
        XCTAssertFalse(makeChecker().isStale)
    }

    func testSkipSuppressesTheNoticeAndPersists() throws {
        try writeFeed("v1.1")
        let checker = makeChecker()
        guard case .available(let release) = checker.state else { return XCTFail("expected an update") }
        checker.skip(release)
        XCTAssertEqual(checker.state, .upToDate)
        // A fresh checker over the same defaults must stay quiet.
        XCTAssertEqual(makeChecker().state, .upToDate)
    }

    func testSkippingDoesNotSilenceALaterVersion() throws {
        try writeFeed("v1.1")
        let checker = makeChecker()
        guard case .available(let release) = checker.state else { return XCTFail("expected an update") }
        checker.skip(release)
        try writeFeed("v1.2")
        checker.refresh()
        XCTAssertEqual(checker.state, .available(
            LatestRelease(tagName: "v1.2", name: nil, body: nil, htmlURL: nil, publishedAt: nil)))
    }

    /// `refresh()` runs on four separate triggers, including every menu bar panel open. A
    /// redundant call must be genuinely inert — that is the same contract `AppStateTests` keeps.
    func testRefreshWithNoChangePublishesNothing() throws {
        try writeFeed("v1.1")
        let checker = makeChecker()
        var notifications = 0
        let token = checker.objectWillChange.sink { _ in notifications += 1 }
        checker.refresh()
        checker.refresh()
        checker.refresh()
        token.cancel()
        XCTAssertEqual(notifications, 0)
    }

    func testRefreshPublishesOnceWhenTheAnswerChanges() throws {
        let checker = makeChecker()
        var notifications = 0
        let token = checker.objectWillChange.sink { _ in notifications += 1 }
        try writeFeed("v1.1")
        checker.refresh()
        checker.refresh()
        token.cancel()
        XCTAssertEqual(notifications, 1)
    }
}
