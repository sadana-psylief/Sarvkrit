import XCTest
@testable import Sarvkrit

/// Saving the index moved off the main thread, because it was re-encoding the whole history —
/// tens of megabytes in the worst case — on every copy, on the thread the event tap's run loop
/// lives on.
///
/// The risk that trade introduces is losing history, so that is what these cover.
final class ClipboardPersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-persist-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeStore() -> ClipboardStore { ClipboardStore(directory: directory) }
    private func text(_ value: String) -> ClipboardItem { ClipboardItem(kind: .text(value)) }

    private func reload() -> [ClipboardItem] { ClipboardStore(directory: directory).items }

    func testAnAddSurvivesAFlush() {
        let store = makeStore()
        store.add(text("hello"), limit: 10)
        store.flush()

        XCTAssertEqual(reload().count, 1)
    }

    func testTheNewestOfABurstIsWhatEndsUpOnDisk() {
        // Writes coalesce, so a burst collapses to one write. It must be the *last* state, not
        // whichever snapshot happened to win a race.
        let store = makeStore()
        for index in 0..<25 {
            store.add(text("entry \(index)"), limit: 100)
        }
        store.flush()

        let reloaded = reload()
        XCTAssertEqual(reloaded.count, 25, "coalescing must not drop entries")
        XCTAssertEqual(ClipboardStore.displayText(for: reloaded[0]), "entry 24",
                       "the newest copy must be on top after a reload")
    }

    func testFlushIsSafeWithNothingPending() {
        let store = makeStore()
        store.flush()
        store.flush()
        XCTAssertTrue(reload().isEmpty)
    }

    func testDeletingPersists() {
        let store = makeStore()
        store.add(text("keep"), limit: 10)
        store.add(text("drop"), limit: 10)
        let doomed = try! XCTUnwrap(store.items.first { ClipboardStore.displayText(for: $0) == "drop" })
        store.delete(id: doomed.id)
        store.flush()

        let reloaded = reload()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(ClipboardStore.displayText(for: reloaded[0]), "keep")
    }

    func testPinningPersists() {
        let store = makeStore()
        store.add(text("pin me"), limit: 10)
        store.setPinned(true, id: store.items[0].id)
        store.flush()

        XCTAssertTrue(reload()[0].isPinned)
    }

    func testClearingPersists() {
        let store = makeStore()
        store.add(text("a"), limit: 10)
        store.flush()
        store.clearHistory()
        store.flush()

        XCTAssertTrue(reload().isEmpty)
    }

    func testTheCapIsRespectedOnDisk() {
        let store = makeStore()
        for index in 0..<10 {
            store.add(text("entry \(index)"), limit: 3)
        }
        store.flush()

        XCTAssertEqual(reload().count, 3)
    }

    func testWritesLandWithoutAnExplicitFlush() {
        // Flush exists for quitting; ordinary use must not depend on it.
        let store = makeStore()
        store.add(text("eventually"), limit: 10)

        let landed = expectation(description: "index written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if !ClipboardStore(directory: self.directory).items.isEmpty { landed.fulfill() }
        }
        wait(for: [landed], timeout: 3)
    }
}
