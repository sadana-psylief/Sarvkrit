import XCTest
@testable import Sarvkrit

/// Decoding is tested against a *captured real* `api.github.com` response rather than a
/// hand-written one. A fixture written by hand encodes our assumptions about the payload; this
/// one encodes GitHub's actual behaviour, which is the thing that can surprise us.
final class LatestReleaseTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/github-latest-release.json")

    private func fixtureData() throws -> Data {
        try Data(contentsOf: Self.fixtureURL)
    }

    func testDecodesTheRealPayload() throws {
        let release = try JSONDecoder().decode(LatestRelease.self, from: fixtureData())
        XCTAssertEqual(release.tagName, "v1.0")
        XCTAssertEqual(release.name, "Sarvkrit 1.0")
        XCTAssertEqual(release.htmlURL, "https://github.com/sadana-psylief/Sarvkrit/releases/tag/v1.0")
        XCTAssertEqual(release.publishedAt, "2026-09-03T17:19:01Z")
        XCTAssertEqual(release.version, AppVersion("1.0"))
        XCTAssertNotNil(release.notesURL)
    }

    /// A release published with no notes really does come back as `"body": null`. A non-optional
    /// `body` would fail the whole decode and cost us the version, which is the field that matters.
    func testDecodesAReleaseWithNoNotes() throws {
        let json = #"{"tag_name":"v2.0","name":null,"body":null,"html_url":null,"published_at":null}"#
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(json.utf8))
        XCTAssertEqual(release.version, AppVersion("2.0"))
        XCTAssertNil(release.displayNotes())
        XCTAssertNil(release.notesURL)
    }

    /// Missing keys, not just null ones — GitHub is free to stop sending a field we don't need.
    func testDecodesWithOnlyATag() throws {
        let release = try JSONDecoder().decode(LatestRelease.self, from: Data(#"{"tag_name":"v3.1"}"#.utf8))
        XCTAssertEqual(release.version, AppVersion("3.1"))
    }

    /// The real v1.0 body: a summary sentence, then "## Install" and two thousand characters of
    /// DMG instructions, a checksum and the licence. Showing that to someone who has just been
    /// handed a curl command is worse than showing nothing.
    func testNotesStopAtTheFirstSectionHeading() throws {
        let release = try JSONDecoder().decode(LatestRelease.self, from: fixtureData())
        let notes = try XCTUnwrap(release.displayNotes())
        XCTAssertTrue(notes.hasPrefix("**Sarvkrit lives in the menu bar"), notes)
        XCTAssertFalse(notes.contains("#"), "a heading leaked into the summary")
        XCTAssertFalse(notes.contains("Download"), "install instructions leaked into the summary")
        XCTAssertFalse(notes.contains("PolyForm"), "the licence leaked into the summary")
    }

    /// Some releases open with a title line before any prose.
    /// Built through JSONSerialization rather than a raw string literal: these bodies contain
    /// `"##`, which closes a `##"..."##` raw string early and makes the escaping a puzzle.
    private func release(body: String) throws -> LatestRelease {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v2.0", "body": body])
        return try JSONDecoder().decode(LatestRelease.self, from: data)
    }

    /// Some releases open with a title line before any prose.
    func testALeadingHeadingIsSkippedRatherThanEndingTheSummary() throws {
        let release = try release(body: "# Sarvkrit 2.0\n\nFaster, and quieter.\n\n## Install\n\nDrag it.")
        XCTAssertEqual(release.displayNotes(), "Faster, and quieter.")
    }

    func testABodyThatIsOnlyHeadingsHasNoSummary() throws {
        XCTAssertNil(try release(body: "## Install\n\nDrag it.").displayNotes())
    }

    func testNotesAreCappedForDisplay() throws {
        let release = try JSONDecoder().decode(
            LatestRelease.self,
            from: Data(#"{"tag_name":"v1.0","body":"\#(String(repeating: "x", count: 50))"}"#.utf8))
        let notes = try XCTUnwrap(release.displayNotes(limit: 10))
        XCTAssertEqual(notes, String(repeating: "x", count: 10) + "…")
    }

    func testWhitespaceOnlyNotesAreTreatedAsNone() throws {
        let release = try JSONDecoder().decode(
            LatestRelease.self, from: Data(#"{"tag_name":"v1.0","body":"   \n  "}"#.utf8))
        XCTAssertNil(release.displayNotes())
    }
}

final class UpdateFeedStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ contents: String, to name: String) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }

    func testReadsASnapshot() throws {
        try write(#"{"tag_name":"v1.2.3"}"#, to: UpdateFeedStore.feedFileName)
        let snapshot = try XCTUnwrap(UpdateFeedStore(directory: directory).read())
        XCTAssertEqual(snapshot.release.version, AppVersion("1.2.3"))
        XCTAssertLessThan(abs(snapshot.checkedAt.timeIntervalSinceNow), 30)
    }

    func testMissingFileIsNotAnError() {
        XCTAssertNil(UpdateFeedStore(directory: directory).read())
    }

    /// Same rule as `RuleStore`: an undecodable file is kept, not replaced. It is evidence about
    /// what GitHub actually returned, and the next run of the job overwrites it anyway.
    func testCorruptFileIsKeptAndReadsAsNothing() throws {
        try write("<html>captive portal</html>", to: UpdateFeedStore.feedFileName)
        XCTAssertNil(UpdateFeedStore(directory: directory).read())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(UpdateFeedStore.feedFileName).path))
    }

    func testFailureMarkerIsReadByModificationTime() throws {
        let store = UpdateFeedStore(directory: directory)
        XCTAssertNil(store.lastFailureAt)
        try write("", to: UpdateFeedStore.failureMarkerName)
        XCTAssertNotNil(store.lastFailureAt)
    }

    /// The script hardcodes `$HOME/Library/Application Support/Sarvkrit`. If Swift ever resolves
    /// somewhere else the feature silently does nothing and says nothing about why.
    func testDefaultDirectoryMatchesThePathTheScriptWritesTo() {
        XCTAssertEqual(
            UpdateFeedStore.defaultDirectory.standardizedFileURL.path,
            NSHomeDirectory() + "/Library/Application Support/Sarvkrit")
    }
}
