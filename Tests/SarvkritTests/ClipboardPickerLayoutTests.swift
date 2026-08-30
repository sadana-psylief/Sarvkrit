import XCTest
@testable import Sarvkrit

/// The picker used to be a fixed 420pt tall whatever it held, so five rows left roughly half the
/// panel empty. These pin the sizing so that can't come back.
final class ClipboardPickerLayoutTests: XCTestCase {
    private var settings = ClipboardSettings()

    private func text(_ value: String = "hello", copies: Int = 1) -> ClipboardItem {
        ClipboardItem(kind: .text(value), copyCount: copies)
    }

    private func image() -> ClipboardItem {
        ClipboardItem(kind: .image(fileName: "a.png", width: 100, height: 80, byteCount: 1_000))
    }

    // MARK: - Growing with content

    func testHeightGrowsWithRowCount() {
        let one = ClipboardPickerLayout.panelHeight(for: [text()], settings: settings)
        let five = ClipboardPickerLayout.panelHeight(for: Array(repeating: text(), count: 5), settings: settings)
        XCTAssertGreaterThan(five, one)
    }

    func testFiveTextRowsDoNotFillTheOldFixedHeight() {
        // The actual complaint: five rows in a 420pt panel left ~220pt of dead space.
        let five = ClipboardPickerLayout.panelHeight(for: Array(repeating: text(), count: 5), settings: settings)
        XCTAssertLessThan(five, 420, "five rows should not need the old fixed height")
        XCTAssertGreaterThan(five, ClipboardPickerLayout.minimumHeight)
    }

    func testHeightStopsAtTheMaximum() {
        // A 200-entry history must not ask for a 2,000pt panel.
        let many = Array(repeating: text(), count: 200)
        XCTAssertEqual(
            ClipboardPickerLayout.panelHeight(for: many, settings: settings),
            ClipboardPickerLayout.maximumHeight)
    }

    func testHeightNeverDropsBelowTheMinimum() {
        // Zero results still needs room to say "Nothing copied yet".
        XCTAssertEqual(
            ClipboardPickerLayout.panelHeight(for: [], settings: settings),
            ClipboardPickerLayout.minimumHeight)
        XCTAssertGreaterThanOrEqual(
            ClipboardPickerLayout.panelHeight(for: [text()], settings: settings),
            ClipboardPickerLayout.minimumHeight)
    }

    // MARK: - Row heights follow content

    func testARowWithoutASubtitleIsShorterThanOneWithIt() {
        // The regression that would bring back the invisible second line.
        let plain = ClipboardPickerLayout.rowHeight(for: text(), settings: settings)
        let withSubtitle = ClipboardPickerLayout.rowHeight(for: text(copies: 4), settings: settings)
        XCTAssertLessThan(plain, withSubtitle)
        XCTAssertEqual(plain, ClipboardPickerLayout.singleLineRowHeight)
    }

    func testAPlainTextRowHasNoSubtitle() {
        // The common case, and the one that was silently laying out an empty line.
        XCTAssertFalse(ClipboardPickerLayout.hasSubtitle(text(), settings: settings))
    }

    func testEntriesWithSomethingToSayGetASubtitle() {
        XCTAssertTrue(ClipboardPickerLayout.hasSubtitle(text(copies: 2), settings: settings))
        XCTAssertTrue(ClipboardPickerLayout.hasSubtitle(image(), settings: settings))
        XCTAssertTrue(ClipboardPickerLayout.hasSubtitle(
            ClipboardItem(kind: .files(["/tmp/a"])), settings: settings))
    }

    func testTurningOffAppIconsMovesTheSourceIntoTheSubtitle() {
        // With icons off the source has to be shown as text, which needs the second line back.
        var item = text()
        item.sourceBundleID = "com.apple.Notes"
        XCTAssertFalse(ClipboardPickerLayout.hasSubtitle(item, settings: settings))

        settings.showAppIcons = false
        XCTAssertTrue(ClipboardPickerLayout.hasSubtitle(item, settings: settings))
    }

    // MARK: - Images

    func testAnImageRowIsTallerAndFollowsTheConfiguredHeight() {
        let short = ClipboardPickerLayout.rowHeight(for: image(), settings: settings)
        settings.imageRowHeight = 100
        let tall = ClipboardPickerLayout.rowHeight(for: image(), settings: settings)

        XCTAssertGreaterThan(tall, short)
        XCTAssertGreaterThan(short, ClipboardPickerLayout.singleLineRowHeight)
    }

    func testImagesMakeThePanelTallerThanTheSameNumberOfTextRows() {
        let texts = ClipboardPickerLayout.panelHeight(for: Array(repeating: text(), count: 3), settings: settings)
        let images = ClipboardPickerLayout.panelHeight(for: Array(repeating: image(), count: 3), settings: settings)
        XCTAssertGreaterThan(images, texts)
    }

    func testAVeryLargeImageHeightStillRespectsThePanelMaximum() {
        settings.imageRowHeight = 120
        let height = ClipboardPickerLayout.panelHeight(for: Array(repeating: image(), count: 20), settings: settings)
        XCTAssertEqual(height, ClipboardPickerLayout.maximumHeight)
    }

    func testWidthIsFixed() {
        XCTAssertEqual(
            ClipboardPickerLayout.panelSize(for: [text()], settings: settings).width,
            ClipboardPickerLayout.width)
    }
}
