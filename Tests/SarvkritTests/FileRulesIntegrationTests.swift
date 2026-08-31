import XCTest
@testable import Sarvkrit

/// The whole Files pipeline, wired the way the app wires it: a real folder, a real rule, a real
/// FSEvents watcher, and a file dropped in from outside. Every other Files test exercises one
/// layer; this proves they're connected.
final class FileRulesIntegrationTests: XCTestCase {
    private var watched: URL!
    private var storeDirectory: URL!
    private var feature: FileRulesFeature!

    override func setUpWithError() throws {
        try super.setUpWithError()
        watched = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-watched-\(UUID().uuidString)")
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        feature?.deactivate()
        feature = nil
        try? FileManager.default.removeItem(at: watched)
        try? FileManager.default.removeItem(at: storeDirectory)
        try super.tearDownWithError()
    }

    private func makeFeature(rules: [Rule]) -> FileRulesFeature {
        let store = RuleStore(directory: storeDirectory)
        store.replace(with: rules)
        return FileRulesFeature(store: store)
    }

    private func sortRule(enabled: Bool = true) throws -> Rule {
        Rule(
            name: "Sort text files",
            isEnabled: enabled,
            folderBookmark: try XCTUnwrap(ActionRunner.bookmark(for: watched)),
            conditions: [Condition(attribute: .fileExtension, comparison: .isExactly, value: .text("txt"))],
            actions: [.sortIntoSubfolder(pattern: "Text")]
        )
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: watched.appendingPathComponent(path).path)
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    func testExistingFilesAreSweptWhenTheFeatureActivates() throws {
        try "x".write(to: watched.appendingPathComponent("already.txt"), atomically: true, encoding: .utf8)
        feature = makeFeature(rules: [try sortRule()])

        feature.activate()

        // The initial sweep runs on the feature's work queue rather than the caller's thread: it
        // walks every watched folder and moves files, and it used to do that on main from inside
        // `AppState.sync()` — where the event tap is also waiting.
        waitUntil { self.exists("Text/already.txt") }
        XCTAssertTrue(exists("Text/already.txt"), "activation should file what's already there")
    }

    func testAFileArrivingLaterIsFiledByTheWatcher() throws {
        feature = makeFeature(rules: [try sortRule()])
        feature.activate()

        // Written after the stream is running, which is what FSEvents reports on.
        try "x".write(to: watched.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)

        waitUntil { self.exists("Text/later.txt") }
        XCTAssertTrue(exists("Text/later.txt"), "the watcher never filed the new file")
    }

    func testNonMatchingFilesAreLeftAlone() throws {
        try "x".write(to: watched.appendingPathComponent("photo.png"), atomically: true, encoding: .utf8)
        feature = makeFeature(rules: [try sortRule()])

        feature.activate()

        XCTAssertTrue(exists("photo.png"))
        XCTAssertFalse(exists("Text/photo.png"))
    }

    func testADisabledRuleDoesNothing() throws {
        try "x".write(to: watched.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        feature = makeFeature(rules: [try sortRule(enabled: false)])

        feature.activate()

        XCTAssertTrue(exists("a.txt"))
        XCTAssertFalse(exists("Text/a.txt"))
    }

    func testAnIncompleteRuleIsNeverRun() throws {
        // No folder chosen: the rule must be inert rather than failing at action time.
        var incomplete = try sortRule()
        incomplete.folderBookmark = nil
        try "x".write(to: watched.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        feature = makeFeature(rules: [incomplete])
        feature.activate()

        XCTAssertTrue(exists("a.txt"))
    }

    func testEditingRulesRewiresTheWatcherWithoutTogglingTheFeature() throws {
        // The handshake, end to end. Start with a rule pointing nowhere, then complete it — files
        // arriving afterwards must be filed, with no off/on cycle.
        var incomplete = try sortRule()
        incomplete.folderBookmark = nil

        let store = RuleStore(directory: storeDirectory)
        store.replace(with: [incomplete])
        feature = FileRulesFeature(store: store)
        feature.activate()

        var completed = incomplete
        completed.folderBookmark = try XCTUnwrap(ActionRunner.bookmark(for: watched))
        store.update(completed)

        try "x".write(to: watched.appendingPathComponent("after-edit.txt"), atomically: true, encoding: .utf8)

        waitUntil { self.exists("Text/after-edit.txt") }
        XCTAssertTrue(exists("Text/after-edit.txt"),
                      "editing a rule must re-point the watcher without a toggle")
    }

    func testPreviewChangesNothing() throws {
        try "x".write(to: watched.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let rule = try sortRule()
        feature = makeFeature(rules: [rule])

        let reports = feature.preview(rule: rule)

        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(exists("a.txt"), "preview moved a file")
        XCTAssertFalse(exists("Text"), "preview created a folder")
    }

    func testDeactivatingStopsFiling() throws {
        feature = makeFeature(rules: [try sortRule()])
        feature.activate()
        feature.deactivate()

        try "x".write(to: watched.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)

        // Give the watcher every chance to misbehave before concluding it's quiet.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { settled.fulfill() }
        wait(for: [settled], timeout: 10)

        XCTAssertTrue(exists("ignored.txt"))
        XCTAssertFalse(exists("Text/ignored.txt"), "a disabled feature filed a file")
    }
}
