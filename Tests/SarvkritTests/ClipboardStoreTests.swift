import XCTest
@testable import Sarvkrit

final class ClipboardStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-clip-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() -> ClipboardStore {
        ClipboardStore(directory: directory)
    }

    private func textItem(_ value: String, at date: Date = Date()) -> ClipboardItem {
        ClipboardItem(kind: .text(value), createdAt: date)
    }

    private func filesInDirectory() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0 != "clipboard.json" }.sorted() ?? []
    }

    // MARK: - Ordering and dedupe

    func testNewestFirst() {
        let store = makeStore()
        store.add(textItem("first", at: Date(timeIntervalSince1970: 1)), limit: 10)
        store.add(textItem("second", at: Date(timeIntervalSince1970: 2)), limit: 10)

        XCTAssertEqual(store.ordered().map(\.searchableText), ["second", "first"])
    }

    func testRecopyingTheSameThingMovesItRatherThanDuplicating() {
        let store = makeStore()
        store.add(textItem("a", at: Date(timeIntervalSince1970: 1)), limit: 10)
        store.add(textItem("b", at: Date(timeIntervalSince1970: 2)), limit: 10)
        store.add(textItem("a", at: Date(timeIntervalSince1970: 3)), limit: 10)

        XCTAssertEqual(store.items.count, 2, "a duplicate entry was created")
        XCTAssertEqual(store.ordered().map(\.searchableText), ["a", "b"])
    }

    func testADedupeMergeDeletesTheRedundantPayload() {
        // The repeat copy's file is not needed — the existing entry already has one. Keeping it
        // would orphan a file for every repeated copy.
        let store = makeStore()
        let firstName = try! XCTUnwrap(store.writePayload(Data("img".utf8), extension: "png"))
        store.add(ClipboardItem(kind: .image(fileName: firstName, width: 1, height: 1, byteCount: 3)), limit: 10)

        let secondName = try! XCTUnwrap(store.writePayload(Data("img".utf8), extension: "png"))
        store.add(ClipboardItem(kind: .image(fileName: secondName, width: 1, height: 1, byteCount: 3)), limit: 10)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(filesInDirectory(), [firstName], "the redundant payload was orphaned")
    }

    // MARK: - The cap

    func testTheCapEvictsOldestFirst() {
        let store = makeStore()
        for index in 0..<5 {
            store.add(textItem("item\(index)", at: Date(timeIntervalSince1970: TimeInterval(index))), limit: 3)
        }
        XCTAssertEqual(store.ordered().map(\.searchableText), ["item4", "item3", "item2"])
    }

    func testEvictionDeletesBackingFiles() {
        let store = makeStore()
        var names: [String] = []
        for index in 0..<4 {
            let name = try! XCTUnwrap(store.writePayload(Data("i\(index)".utf8), extension: "png"))
            names.append(name)
            store.add(
                ClipboardItem(
                    kind: .image(fileName: name, width: index, height: 1, byteCount: index),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))),
                limit: 2)
        }
        // The two oldest were evicted; their files must have gone with them.
        XCTAssertEqual(filesInDirectory(), Array(names.suffix(2)).sorted())
    }

    func testPinnedEntriesAreNeverEvicted() {
        let store = makeStore()
        let pinned = ClipboardItem(
            kind: .text("keep me"), createdAt: Date(timeIntervalSince1970: 0), isPinned: true)
        store.add(pinned, limit: 2)

        for index in 1...10 {
            store.add(textItem("noise\(index)", at: Date(timeIntervalSince1970: TimeInterval(index))), limit: 2)
        }

        XCTAssertTrue(store.items.contains { $0.searchableText == "keep me" },
                      "a pinned entry aged out — pins exist precisely to prevent that")
    }

    func testPinnedEntriesSortAboveTheRollingHistory() {
        let store = makeStore()
        store.add(textItem("recent", at: Date(timeIntervalSince1970: 100)), limit: 10)
        store.add(ClipboardItem(kind: .text("old pin"),
                                createdAt: Date(timeIntervalSince1970: 1), isPinned: true), limit: 10)

        XCTAssertEqual(store.ordered().map(\.searchableText), ["old pin", "recent"])
    }

    func testPinningIsPersisted() {
        let store = makeStore()
        let item = textItem("pin me")
        store.add(item, limit: 10)
        store.setPinned(true, id: item.id)

        XCTAssertTrue(makeStore().items.first { $0.id == item.id }?.isPinned == true)
    }

    // MARK: - Clearing

    func testClearHistoryEmptiesTheDirectoryToo() {
        let store = makeStore()
        for index in 0..<3 {
            let name = try! XCTUnwrap(store.writePayload(Data("x".utf8), extension: "png"))
            store.add(ClipboardItem(kind: .image(fileName: name, width: index, height: 1, byteCount: index)),
                      limit: 10)
        }
        store.add(ClipboardItem(kind: .text("pinned"), isPinned: true), limit: 10)

        store.clearHistory()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(filesInDirectory(), [], "clearing left orphaned payload files behind")
        XCTAssertTrue(makeStore().items.isEmpty, "clearing didn't survive a reload")
    }

    // MARK: - Persistence

    func testHistorySurvivesReload() {
        let store = makeStore()
        store.add(textItem("survivor"), limit: 10)
        store.add(ClipboardItem(kind: .files(["/tmp/a.txt"])), limit: 10)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.items.count, 2)
        XCTAssertTrue(reloaded.items.contains { $0.isFileReference })
    }

    func testEveryKindRoundTripsThroughTheIndex() throws {
        let items = [
            ClipboardItem(kind: .text("plain")),
            ClipboardItem(kind: .largeText(fileName: "a.txt", preview: "big…", characterCount: 99)),
            ClipboardItem(kind: .richText(fileName: "b.rtf", plain: "styled")),
            ClipboardItem(kind: .image(fileName: "c.png", width: 2, height: 3, byteCount: 4)),
            ClipboardItem(kind: .files(["/tmp/a", "/tmp/b"])),
        ]
        let data = try JSONEncoder().encode(items)
        XCTAssertEqual(try JSONDecoder().decode([ClipboardItem].self, from: data), items)
    }

    // MARK: - Search

    func testSearchIsCaseInsensitiveSubstring() {
        let store = makeStore()
        store.add(textItem("Hello World"), limit: 10)
        store.add(textItem("goodbye"), limit: 10)

        XCTAssertEqual(store.search("hello").map(\.displayText), ["Hello World"])
        XCTAssertEqual(store.search("WORLD").map(\.displayText), ["Hello World"])
        XCTAssertTrue(store.search("nothing").isEmpty)
    }

    func testSearchMatchesFilenamesNotFullPaths() {
        let store = makeStore()
        store.add(ClipboardItem(kind: .files(["/Users/someone/Documents/invoice.pdf"])), limit: 10)
        XCTAssertEqual(store.search("invoice").count, 1)
    }

    func testAnEmptyQueryReturnsEverythingInOrder() {
        let store = makeStore()
        store.add(textItem("a", at: Date(timeIntervalSince1970: 1)), limit: 10)
        store.add(textItem("b", at: Date(timeIntervalSince1970: 2)), limit: 10)

        XCTAssertEqual(store.search("").map(\.displayText), ["b", "a"])
        XCTAssertEqual(store.search("   ").map(\.displayText), ["b", "a"])
    }

    // MARK: - Dead references

    func testAMissingFileIsReportedUnresolvable() throws {
        let real = directory.appendingPathComponent("real.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "x".write(to: real, atomically: true, encoding: .utf8)

        XCTAssertTrue(ClipboardItem(kind: .files([real.path])).isResolvable())
        XCTAssertFalse(ClipboardItem(kind: .files(["/nope/\(UUID().uuidString)"])).isResolvable())
        XCTAssertTrue(ClipboardItem(kind: .text("always fine")).isResolvable())
    }
}
