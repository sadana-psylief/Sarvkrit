import XCTest
@testable import Sarvkrit

/// The shelf's contents, and the one invariant that matters most: **a shelf never deletes the
/// user's files.** It holds references; the only things it owns are the payloads it wrote itself.
final class ShelfStoreTests: XCTestCase {
    private var directory: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func makeStore() -> ShelfStore { ShelfStore(directory: directory) }

    /// A real file on disk, so the bookmark paths are genuine.
    private func makeFile(_ name: String, contents: String = "x") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fileItem(_ url: URL) throws -> ShelfItem {
        let bookmark = try XCTUnwrap(ActionRunner.bookmark(for: url))
        return ShelfItem(kind: .files([
            ShelfItem.FileReference(bookmark: bookmark, lastKnownPath: url.path)
        ]))
    }

    private func payloadFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { !$0.hasPrefix("shelf.json") }.sorted() ?? []
    }

    // MARK: - The invariant

    func testRemovingAFileItemNeverDeletesTheFile() throws {
        // The single most important test here. A shelf that ate your documents when you tidied it
        // would be catastrophic, and `backingFileNames` returning [] for `.files` is what prevents
        // it — structurally, not by remembering to check.
        let url = try makeFile("keep-me.txt")
        let store = makeStore()
        let item = try fileItem(url)
        store.add([item])

        store.remove(id: item.id)
        store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the user's file must survive being taken off the shelf")
    }

    func testClearingNeverDeletesReferencedFiles() throws {
        let first = try makeFile("a.txt")
        let second = try makeFile("b.txt")
        let store = makeStore()
        store.add([try fileItem(first), try fileItem(second)])

        store.clear()
        store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testAFileItemOwnsNoBackingFiles() throws {
        let item = try fileItem(try makeFile("a.txt"))
        XCTAssertTrue(item.backingFileNames.isEmpty)
    }

    // MARK: - Payloads the shelf DOES own

    func testRemovingAnImageItemDeletesItsPayload() {
        let store = makeStore()
        let name = store.writePayload(Data("png".utf8), extension: "png")!
        let item = ShelfItem(kind: .image(fileName: name, width: 1, height: 1, byteCount: 3))
        store.add([item])
        XCTAssertEqual(payloadFiles(), [name], "precondition")

        store.remove(id: item.id)
        store.flush()
        XCTAssertEqual(payloadFiles(), [], "a payload the shelf wrote is the shelf's to delete")
    }

    func testClearingDeletesEveryOwnedPayloadButLeavesReferences() throws {
        let store = makeStore()
        let name = store.writePayload(Data("png".utf8), extension: "png")!
        let file = try makeFile("survivor.txt")
        store.add([
            ShelfItem(kind: .image(fileName: name, width: 1, height: 1, byteCount: 3)),
            try fileItem(file),
        ])

        store.clear()
        store.flush()

        XCTAssertEqual(payloadFiles(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Following a file that moves

    func testAParkedFileIsFoundAfterBeingRenamed() throws {
        // Why bookmarks rather than paths, in one test.
        let url = try makeFile("before.txt")
        let store = makeStore()
        let item = try fileItem(url)
        store.add([item])

        let moved = scratch.appendingPathComponent("after.txt")
        try FileManager.default.moveItem(at: url, to: moved)

        guard case .files(let references) = store.items[0].kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(store.resolve(references[0])?.lastPathComponent, "after.txt")
        XCTAssertTrue(store.isResolvable(store.items[0]))
    }

    func testAParkedFileThatIsDeletedStopsResolving() throws {
        // So the row can be greyed out rather than offering a drag that does nothing.
        let url = try makeFile("doomed.txt")
        let store = makeStore()
        store.add([try fileItem(url)])

        try FileManager.default.removeItem(at: url)

        XCTAssertFalse(store.isResolvable(store.items[0]))
    }

    func testNonFileItemsAlwaysResolve() {
        let store = makeStore()
        XCTAssertTrue(store.isResolvable(ShelfItem(kind: .text("hello"))))
    }

    // MARK: - Ordering and grouping

    func testNewestParkedItemIsFirst() {
        let store = makeStore()
        store.add([ShelfItem(kind: .text("first"))])
        store.add([ShelfItem(kind: .text("second"))])
        XCTAssertEqual(store.items.first?.displayText, "second")
    }

    func testItemsDroppedTogetherShareAGroup() throws {
        // "Groups compatible drops": a multi-file drag is one row, not N loose ones.
        let store = makeStore()
        let urls = [try makeFile("a.txt"), try makeFile("b.txt")]
        let references = try urls.map { url in
            ShelfItem.FileReference(
                bookmark: try XCTUnwrap(ActionRunner.bookmark(for: url)), lastKnownPath: url.path
            )
        }
        let group = UUID()
        store.add([ShelfItem(kind: .files(references), groupID: group)])

        XCTAssertEqual(store.items.count, 1, "two files, one row")
        XCTAssertEqual(store.items[0].groupID, group)
        XCTAssertTrue(store.items[0].displayText.contains("and 1 more"))
    }

    // MARK: - Persistence

    func testTheShelfSurvivesARelaunch() throws {
        let url = try makeFile("parked.txt")
        let store = makeStore()
        store.add([try fileItem(url), ShelfItem(kind: .text("note"))])
        store.flush()

        let reloaded = ShelfStore(directory: directory)
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertTrue(reloaded.isResolvable(reloaded.items.first { $0.isFileReference }!))
    }

    func testAddingNothingIsHarmless() {
        let store = makeStore()
        store.add([])
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRemovingSeveralAtOnce() {
        let store = makeStore()
        let items = [ShelfItem(kind: .text("a")), ShelfItem(kind: .text("b")),
                     ShelfItem(kind: .text("c"))]
        store.add(items)
        store.remove(ids: Set(items.prefix(2).map(\.id)))
        XCTAssertEqual(store.items.map(\.displayText), ["c"])
    }

    func testABatchKeepsItsOwnOrderWhileGoingOnTop() {
        // Newest *batch* first, but a multi-item drop keeps the order it was dropped in — dragging
        // three files shouldn't reverse them.
        let store = makeStore()
        store.add([ShelfItem(kind: .text("old"))])
        store.add([ShelfItem(kind: .text("new 1")), ShelfItem(kind: .text("new 2"))])
        XCTAssertEqual(store.items.map(\.displayText), ["new 1", "new 2", "old"])
    }
}
