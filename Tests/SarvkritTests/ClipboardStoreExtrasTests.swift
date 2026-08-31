import XCTest
@testable import Sarvkrit

/// Per-item delete, copy counting, and the display text that highlight ranges depend on.
final class ClipboardStoreExtrasTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-extras-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() -> ClipboardStore { ClipboardStore(directory: directory) }

    private func filesInDirectory() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0 != "clipboard.json" }.sorted() ?? []
    }

    // MARK: - Copy counting

    func testRecopyingIncrementsTheCountAndKeepsTheFirstCopyDate() {
        let store = makeStore()
        let first = Date(timeIntervalSince1970: 100)
        store.add(ClipboardItem(kind: .text("again"), createdAt: first), limit: 10)
        store.add(ClipboardItem(kind: .text("again"), createdAt: Date(timeIntervalSince1970: 900)), limit: 10)

        let item = try! XCTUnwrap(store.items.first)
        XCTAssertEqual(item.copyCount, 2)
        XCTAssertEqual(item.firstCopiedAt, first, "‘time of first copy’ must not move on a repeat")
        XCTAssertEqual(item.createdAt, Date(timeIntervalSince1970: 900))
    }

    func testCopyCountSurvivesAReload() {
        let store = makeStore()
        store.add(ClipboardItem(kind: .text("x")), limit: 10)
        store.add(ClipboardItem(kind: .text("x")), limit: 10)
        store.flush()   // writes are coalesced onto a background queue; force one
        XCTAssertEqual(makeStore().items.first?.copyCount, 2)
    }

    // MARK: - Per-item delete

    func testDeletingOneEntryLeavesTheRest() {
        let store = makeStore()
        let doomed = ClipboardItem(kind: .text("delete me"))
        store.add(doomed, limit: 10)
        store.add(ClipboardItem(kind: .text("keep me")), limit: 10)

        store.delete(id: doomed.id)
        store.flush()

        XCTAssertEqual(store.items.map(\.searchableText), ["keep me"])
        XCTAssertEqual(makeStore().items.map(\.searchableText), ["keep me"], "the delete didn't persist")
    }

    func testDeletingRemovesItsBackingFileButNotOthers() {
        let store = makeStore()
        let keepName = try! XCTUnwrap(store.writePayload(Data("keep".utf8), extension: "png"))
        let keep = ClipboardItem(kind: .image(fileName: keepName, width: 1, height: 1, byteCount: 4))
        store.add(keep, limit: 10)

        let dropName = try! XCTUnwrap(store.writePayload(Data("drop".utf8), extension: "png"))
        let drop = ClipboardItem(kind: .image(fileName: dropName, width: 2, height: 2, byteCount: 4))
        store.add(drop, limit: 10)

        store.delete(id: drop.id)
        // Also settles the index write, whose atomic temp file would otherwise show up here.
        store.flush()

        XCTAssertEqual(filesInDirectory(), [keepName], "delete orphaned or over-deleted files")
    }

    func testDeletingAnUnknownIdIsHarmless() {
        let store = makeStore()
        store.add(ClipboardItem(kind: .text("x")), limit: 10)
        store.delete(id: UUID())
        XCTAssertEqual(store.items.count, 1)
    }

    // MARK: - Display text is what search and highlighting share

    func testDisplayTextCollapsesNewlinesSoRangesMatchWhatIsDrawn() {
        // The row draws this string; the matcher searches this string. If they differ, highlight
        // ranges land on the wrong characters — or out of bounds.
        let item = ClipboardItem(kind: .text("  line one\nline two\ttabbed  "))
        let display = ClipboardStore.displayText(for: item)

        XCTAssertEqual(display, "line one line two tabbed")
        XCTAssertFalse(display.contains("\n"))
    }

    func testSearchResultsCarryRangesIntoTheirOwnDisplayText() {
        let store = makeStore()
        store.add(ClipboardItem(kind: .text("first line\nsecond line")), limit: 10)

        let results = store.search("second", mode: .exact)
        XCTAssertEqual(results.count, 1)

        let result = results[0]
        for range in result.ranges {
            XCTAssertLessThanOrEqual(range.upperBound, result.displayText.endIndex)
        }
        XCTAssertEqual(result.ranges.map { String(result.displayText[$0]) }, ["second"])
    }

    func testSearchRespectsTheChosenMode() {
        let store = makeStore()
        store.add(ClipboardItem(kind: .text("invoice-2026.pdf")), limit: 10)

        XCTAssertTrue(store.search("invpdf", mode: .exact).isEmpty)
        XCTAssertEqual(store.search("invpdf", mode: .fuzzy).count, 1)
    }

    func testEvictionStaysRecencyBasedRegardlessOfSort() {
        // Evicting by lowest copy count would quietly delete something copied once and kept
        // deliberately.
        let store = makeStore()
        store.add(ClipboardItem(kind: .text("old but popular"),
                                createdAt: Date(timeIntervalSince1970: 1), copyCount: 99), limit: 2)
        store.add(ClipboardItem(kind: .text("newer a"), createdAt: Date(timeIntervalSince1970: 10)), limit: 2)
        store.add(ClipboardItem(kind: .text("newer b"), createdAt: Date(timeIntervalSince1970: 20)), limit: 2)

        XCTAssertEqual(Set(store.items.map(\.searchableText)), ["newer a", "newer b"])
    }
}
