import XCTest
@testable import Sarvkrit

/// Tile metrics and the preview cache. Quick Look's actual output can't be tested — it depends on
/// the file and the system — but the cache's bookkeeping around it can.
final class ShelfLayoutTests: XCTestCase {

    func testThePanelIsWideEnoughForItsColumns() {
        // The width is derived rather than picked, so the two can't drift into a grid that wraps
        // at two columns inside a panel sized for three.
        let needed = CGFloat(ShelfLayout.columnCount) * ShelfLayout.tile
            + CGFloat(ShelfLayout.columnCount + 1) * Theme.Space.md
        XCTAssertEqual(ShelfLayout.panelWidth, needed)
    }

    func testThereAreAsManyColumnsAsAdvertised() {
        XCTAssertEqual(ShelfLayout.columns.count, ShelfLayout.columnCount)
    }

    func testTheThumbnailFitsInsideItsTile() {
        XCTAssertLessThanOrEqual(ShelfLayout.thumbnail.width, ShelfLayout.tile)
        XCTAssertLessThanOrEqual(ShelfLayout.thumbnail.height, ShelfLayout.tile)
    }

    // MARK: - The preview cache

    @MainActor
    func testAnItemWithNoPreviewYetReportsNone() {
        let previews = ShelfThumbnails()
        let item = ShelfItem(kind: .text("no file here"))
        XCTAssertNil(previews.cached(item.id))
    }

    @MainActor
    func testAskingForANonFileDoesNotStartGeneration() {
        // Text and images have no file to Quick Look; asking must be inert rather than queueing
        // work that can never finish.
        let previews = ShelfThumbnails()
        let item = ShelfItem(kind: .text("hello"))
        XCTAssertNil(previews.thumbnail(
            for: item, url: nil, size: CGSize(width: 56, height: 56), scale: 2
        ))
        XCTAssertNil(previews.cached(item.id))
    }

    @MainActor
    func testForgettingAnItemDropsItsPreview() {
        let previews = ShelfThumbnails()
        let id = UUID()
        previews.forget(id)   // harmless when nothing is cached
        XCTAssertNil(previews.cached(id))
    }

    @MainActor
    func testForgettingEverythingIsHarmlessWhenEmpty() {
        let previews = ShelfThumbnails()
        previews.forgetAll()
        XCTAssertEqual(previews.generation, 0)
    }

    // MARK: - The store drops previews with items

    @MainActor
    func testRemovingAnItemForgetsItsPreview() throws {
        // The cache must not outlive the shelf's contents, or a re-added file would show the old
        // file's preview.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-previews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ShelfStore(directory: directory)
        let item = ShelfItem(kind: .text("note"))
        store.add([item])
        store.remove(id: item.id)

        XCTAssertNil(store.previews.cached(item.id))
        XCTAssertTrue(store.items.isEmpty)
    }
}
