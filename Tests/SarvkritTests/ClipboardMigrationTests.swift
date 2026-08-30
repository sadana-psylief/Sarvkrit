import XCTest
@testable import Sarvkrit

/// Upgrading must not destroy the user's clipboard history.
///
/// `ClipboardStore.load()` empties the history when decoding fails, so a schema change that the
/// decoder can't tolerate would silently wipe everything the moment someone installs a new build —
/// no error, no warning, just an empty list.
final class ClipboardMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// Exactly the shape written by the shipped build: no `copyCount`, no `firstCopiedAt`.
    private static let preMigrationJSON = """
    [
      {
        "id": "11111111-1111-1111-1111-111111111111",
        "kind": { "text": { "_0": "an old copy" } },
        "createdAt": 750000000,
        "isPinned": true,
        "sourceBundleID": "com.apple.TextEdit"
      },
      {
        "id": "22222222-2222-2222-2222-222222222222",
        "kind": { "files": { "_0": ["/tmp/a.txt"] } },
        "createdAt": 750000100,
        "isPinned": false
      }
    ]
    """

    func testHistorySavedBeforeTheseFieldsExistedStillLoads() throws {
        try Self.preMigrationJSON.write(
            to: directory.appendingPathComponent("clipboard.json"), atomically: true, encoding: .utf8)

        let store = ClipboardStore(directory: directory)

        XCTAssertEqual(store.items.count, 2, "upgrading wiped the user's clipboard history")
        XCTAssertEqual(store.items.first { $0.isPinned }?.searchableText, "an old copy")
    }

    func testMissingFieldsGetHonestDefaults() throws {
        try Self.preMigrationJSON.write(
            to: directory.appendingPathComponent("clipboard.json"), atomically: true, encoding: .utf8)

        let store = ClipboardStore(directory: directory)
        let old = try XCTUnwrap(store.items.first { $0.searchableText == "an old copy" })

        // Seen at least once, and the only "first copied" we can honestly claim is when we last
        // saw it — not `Date()`, which would sort every migrated entry as brand new.
        XCTAssertEqual(old.copyCount, 1)
        XCTAssertEqual(old.firstCopiedAt, old.createdAt)
    }

    func testPinnedStateAndSourceSurviveTheUpgrade() throws {
        try Self.preMigrationJSON.write(
            to: directory.appendingPathComponent("clipboard.json"), atomically: true, encoding: .utf8)

        let store = ClipboardStore(directory: directory)
        let old = try XCTUnwrap(store.items.first { $0.searchableText == "an old copy" })

        XCTAssertTrue(old.isPinned, "a pinned entry lost its pin on upgrade")
        XCTAssertEqual(old.sourceBundleID, "com.apple.TextEdit")
    }

    func testTheNewShapeStillRoundTrips() throws {
        let item = ClipboardItem(
            kind: .text("current"),
            createdAt: Date(timeIntervalSince1970: 900),
            firstCopiedAt: Date(timeIntervalSince1970: 100),
            copyCount: 7,
            sourceBundleID: "com.example.app",
            isPinned: true
        )
        let data = try JSONEncoder().encode([item])
        XCTAssertEqual(try JSONDecoder().decode([ClipboardItem].self, from: data), [item])
    }

    func testFirstCopiedDefaultsToCreatedWhenNotGiven() {
        let created = Date(timeIntervalSince1970: 500)
        XCTAssertEqual(ClipboardItem(kind: .text("x"), createdAt: created).firstCopiedAt, created)
    }
}
