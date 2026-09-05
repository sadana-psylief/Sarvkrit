import XCTest
@testable import Sarvkrit

/// Drives the *shipped* script — the exact bytes inside the app bundle — rather than a copy in
/// the source tree, so a build that mangles it fails here. `SARVKRIT_UPDATE_URL` and
/// `SARVKRIT_UPDATE_DIR` exist for this: curl handles `file://`, so the whole thing runs against
/// a fixture and a temp directory with no network involved.
///
/// Shelling out in a test has precedent here — `SleepDisableFlag` does the same with `pmset`.
final class UpdateScriptTests: XCTestCase {
    private var directory: URL!
    private var script: URL!
    private var fixture: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Bundle.main.bundleIdentifier == AppIdentity.bundleID,
                          "not hosted in Sarvkrit.app — the shipped script isn't reachable")
        script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent(UpdateCheckAgent.scriptName)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: script.path),
                          "the shipped script is missing or not executable")
        fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/github-latest-release.json")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func runScript(url: URL? = nil, force: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = script
        process.arguments = force ? ["--force"] : []
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "SARVKRIT_UPDATE_DIR": directory.path,
            "SARVKRIT_UPDATE_URL": (url ?? fixture).absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private var feed: URL { directory.appendingPathComponent(UpdateFeedStore.feedFileName) }
    private var marker: URL { directory.appendingPathComponent(UpdateFeedStore.failureMarkerName) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func mtime(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    func testWritesAFeedTheStoreCanRead() throws {
        XCTAssertEqual(try runScript(), 0)
        let snapshot = try XCTUnwrap(UpdateFeedStore(directory: directory).read())
        XCTAssertEqual(snapshot.release.tagName, "v1.0")
    }

    /// launchd fires the job every six hours; the throttle is what makes it fetch once a day.
    func testASecondRunInsideTheWindowDoesNothing() throws {
        try runScript()
        let before = try mtime(feed)
        try runScript()
        XCTAssertEqual(try mtime(feed), before)
    }

    /// "Check Now" would be a no-op most of the time without this.
    func testForceBeatsTheThrottle() throws {
        try runScript()
        let before = try mtime(feed)
        Thread.sleep(forTimeInterval: 1.1)
        try runScript(force: true)
        XCTAssertNotEqual(try mtime(feed), before)
    }

    /// A stale-but-real answer beats no answer, and an empty file would make every later read log
    /// a decode failure forever.
    func testAFailedFetchKeepsTheLastGoodAnswer() throws {
        try runScript()
        let good = try Data(contentsOf: feed)
        XCTAssertEqual(try runScript(url: URL(fileURLWithPath: "/nonexistent/nothing.json"), force: true), 0)
        XCTAssertEqual(try Data(contentsOf: feed), good)
        XCTAssertTrue(exists(marker), "a failed check must leave the marker the app reads")
    }

    /// A captive portal's login page is a successful HTTP response full of HTML.
    func testANonJSONResponseIsRejected() throws {
        try runScript()
        let good = try Data(contentsOf: feed)
        let html = directory.appendingPathComponent("portal.html")
        try Data("<html>sign in</html>".utf8).write(to: html)
        XCTAssertEqual(try runScript(url: html, force: true), 0)
        XCTAssertEqual(try Data(contentsOf: feed), good)
        XCTAssertTrue(exists(marker))
    }

    /// A non-zero exit makes launchd back the job off and eventually stop firing it. The script's
    /// own throttle is the retry policy, so every failure has to look like success to launchd.
    func testFailureStillExitsZero() throws {
        XCTAssertEqual(try runScript(url: URL(fileURLWithPath: "/nonexistent/nothing.json")), 0)
        XCTAssertFalse(exists(feed))
    }

    func testASucceedingRunClearsTheFailureMarker() throws {
        try runScript(url: URL(fileURLWithPath: "/nonexistent/nothing.json"))
        XCTAssertTrue(exists(marker))
        try runScript(force: true)
        XCTAssertFalse(exists(marker))
    }

    /// The write is a rename inside the destination directory so a reader can never see a partial
    /// file. A leftover temp would mean that isn't happening the way it should.
    func testNoTemporaryFilesAreLeftBehind() throws {
        try runScript()
        try runScript(url: URL(fileURLWithPath: "/nonexistent/nothing.json"), force: true)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".latest-release") }
        XCTAssertEqual(leftovers, [])
    }
}
