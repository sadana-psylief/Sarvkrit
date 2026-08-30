import XCTest
@testable import Sarvkrit

/// Runs against a real temporary directory and asserts the filesystem afterwards. Nothing here is
/// mocked: the whole point of these actions is their effect on disk, and a mock would only prove
/// the mock works.
final class ActionRunnerTests: XCTestCase {
    private var root: URL!
    private let runner = ActionRunner()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ name: String, contents: String = "x", in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func snapshot(_ url: URL) throws -> FileSnapshot {
        try XCTUnwrap(FileInspector.snapshot(of: url))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Move / copy

    func testMoveRelocatesTheFile() throws {
        let source = try makeFile("a.txt")
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bookmark = try XCTUnwrap(ActionRunner.bookmark(for: destination))

        let results = runner.run([.move(destinationBookmark: bookmark)], on: try snapshot(source), mode: .perform)

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(exists(source), "original should be gone")
        XCTAssertTrue(exists(destination.appendingPathComponent("a.txt")))
    }

    func testCopyLeavesTheOriginal() throws {
        let source = try makeFile("a.txt")
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bookmark = try XCTUnwrap(ActionRunner.bookmark(for: destination))

        _ = runner.run([.copy(destinationBookmark: bookmark)], on: try snapshot(source), mode: .perform)

        XCTAssertTrue(exists(source))
        XCTAssertTrue(exists(destination.appendingPathComponent("a.txt")))
    }

    func testMoveIntoAFolderThatAlreadyHasThatNameDisambiguates() throws {
        let source = try makeFile("a.txt", contents: "new")
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try makeFile("a.txt", contents: "existing", in: destination)
        let bookmark = try XCTUnwrap(ActionRunner.bookmark(for: destination))

        _ = runner.run([.move(destinationBookmark: bookmark)], on: try snapshot(source), mode: .perform)

        // Finder's shape, and crucially the existing file is not overwritten.
        XCTAssertTrue(exists(destination.appendingPathComponent("a 2.txt")))
        let survivor = try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(survivor, "existing", "an existing file must never be clobbered")
    }

    // MARK: - Rename

    func testRenameAppliesTokens() throws {
        let source = try makeFile("report.txt")
        _ = runner.run([.rename(pattern: "{name}-final.{ext}")], on: try snapshot(source), mode: .perform)

        XCTAssertFalse(exists(source))
        XCTAssertTrue(exists(root.appendingPathComponent("report-final.txt")))
    }

    func testRenameToAnExistingNameDisambiguatesRatherThanOverwriting() throws {
        let source = try makeFile("a.txt", contents: "new")
        try makeFile("target.txt", contents: "existing")

        _ = runner.run([.rename(pattern: "target.{ext}")], on: try snapshot(source), mode: .perform)

        XCTAssertTrue(exists(root.appendingPathComponent("target 2.txt")))
        let survivor = try String(contentsOf: root.appendingPathComponent("target.txt"), encoding: .utf8)
        XCTAssertEqual(survivor, "existing")
    }

    func testRenamingToItsOwnNameIsANoOp() throws {
        let source = try makeFile("a.txt")
        let results = runner.run([.rename(pattern: "{fullname}")], on: try snapshot(source), mode: .perform)

        XCTAssertTrue(exists(source))
        if case .success(let outcome) = results[0] {
            XCTAssertTrue(outcome.summary.contains("already in place"))
        } else {
            XCTFail("expected success")
        }
    }

    // MARK: - Sort into subfolder

    func testSortIntoSubfolderCreatesNestedDirectories() throws {
        let source = try makeFile("photo.jpg")
        _ = runner.run([.sortIntoSubfolder(pattern: "{kind}/{date:yyyy}")], on: try snapshot(source), mode: .perform)

        let expected = root
            .appendingPathComponent("Image")
            .appendingPathComponent(Calendar(identifier: .gregorian).component(.year, from: Date()).description)
            .appendingPathComponent("photo.jpg")
        XCTAssertTrue(exists(expected), "expected \(expected.path)")
    }

    func testSubfolderPatternCannotEscapeItsDirectory() throws {
        let source = try makeFile("a.txt")
        // ".." must be sanitised, or a rule could file into the parent of the watched folder.
        _ = runner.run([.sortIntoSubfolder(pattern: "../escaped")], on: try snapshot(source), mode: .perform)

        XCTAssertFalse(exists(root.deletingLastPathComponent().appendingPathComponent("escaped/a.txt")))
        XCTAssertTrue(exists(root.appendingPathComponent("untitled/escaped/a.txt")))
    }

    // MARK: - Trash and tags

    func testMoveToTrashRemovesFromTheFolderAndIsTerminal() throws {
        let source = try makeFile("junk.txt")
        let results = runner.run([.moveToTrash], on: try snapshot(source), mode: .perform)

        XCTAssertFalse(exists(source))
        guard case .success(let outcome) = results[0] else { return XCTFail("expected success") }
        XCTAssertTrue(outcome.isTerminal)
    }

    func testAddTagIsVisibleWhenTheFileIsReadBack() throws {
        let source = try makeFile("tagged.txt")
        _ = runner.run([.addTag("Sarvkrit")], on: try snapshot(source), mode: .perform)

        XCTAssertTrue(try snapshot(source).tags.contains("Sarvkrit"))
    }

    // MARK: - Chaining

    func testActionsAfterATerminalActionDoNotRun() throws {
        let source = try makeFile("a.txt")
        // Trashing then tagging would operate on a path that no longer exists.
        let results = runner.run([.moveToTrash, .addTag("Never")], on: try snapshot(source), mode: .perform)

        XCTAssertEqual(results.count, 1, "the chain must stop after a terminal action")
    }

    func testLaterActionsSeeTheRenamedFile() throws {
        let source = try makeFile("orig.txt")
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bookmark = try XCTUnwrap(ActionRunner.bookmark(for: destination))

        _ = runner.run(
            [.rename(pattern: "renamed.{ext}"), .move(destinationBookmark: bookmark)],
            on: try snapshot(source),
            mode: .perform
        )

        // The move must carry the *new* name, not the original one.
        XCTAssertTrue(exists(destination.appendingPathComponent("renamed.txt")))
        XCTAssertFalse(exists(destination.appendingPathComponent("orig.txt")))
    }

    // MARK: - Dry run

    func testDryRunChangesNothingOnDisk() throws {
        let source = try makeFile("a.txt")
        let destination = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let bookmark = try XCTUnwrap(ActionRunner.bookmark(for: destination))

        let results = runner.run(
            [.rename(pattern: "x.{ext}"), .move(destinationBookmark: bookmark), .addTag("T")],
            on: try snapshot(source),
            mode: .dryRun
        )

        XCTAssertTrue(exists(source), "dry run must not touch the original")
        XCTAssertFalse(exists(destination.appendingPathComponent("x.txt")))
        XCTAssertFalse(exists(root.appendingPathComponent("x.txt")))
        XCTAssertTrue(try snapshot(source).tags.isEmpty)
        XCTAssertEqual(results.count, 3, "a preview still describes every action")
    }

    func testDryRunDescribesWhatWouldHappen() throws {
        let source = try makeFile("a.txt")
        let results = runner.run([.rename(pattern: "b.{ext}")], on: try snapshot(source), mode: .dryRun)

        guard case .success(let outcome) = results[0] else { return XCTFail("expected success") }
        XCTAssertTrue(outcome.summary.contains("b.txt"), "preview should name the result: \(outcome.summary)")
    }

    // MARK: - Failures

    func testUnresolvableDestinationFailsCleanly() throws {
        let source = try makeFile("a.txt")
        let results = runner.run([.move(destinationBookmark: Data("nonsense".utf8))], on: try snapshot(source), mode: .perform)

        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results[0] else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .unresolvableDestination)
        XCTAssertTrue(exists(source), "a failed action must leave the file alone")
    }
}
