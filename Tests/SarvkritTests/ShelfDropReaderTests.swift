import XCTest
@testable import Sarvkrit

/// What a dropped pasteboard resolves to. The ordering rule here is the one that would otherwise
/// only be discoverable by dragging a file and finding its *name* parked instead of the file.
final class ShelfDropReaderTests: XCTestCase {

    // MARK: - The ordering rule

    func testAFileDropParksTheFileNotItsName() {
        // The trap: Finder puts a plain-text representation of the filename on the pasteboard
        // alongside the file itself, so checking text first parks the string "report.pdf".
        let content = ShelfDropReader.resolve(
            fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
            hasImage: false,
            richTextPlain: nil,
            plainText: "report.pdf"
        )
        XCTAssertEqual(content, .files([URL(fileURLWithPath: "/tmp/report.pdf")]))
    }

    func testAnImageFileDropParksTheFileNotTheImageData() {
        // An image *file* dragged from Finder offers TIFF too, which is why files are checked
        // before images rather than after.
        let content = ShelfDropReader.resolve(
            fileURLs: [URL(fileURLWithPath: "/tmp/photo.png")],
            hasImage: true,
            richTextPlain: nil,
            plainText: "photo.png"
        )
        XCTAssertEqual(content, .files([URL(fileURLWithPath: "/tmp/photo.png")]))
    }

    func testImageDataWithNoFileIsAnImage() {
        // A screenshot dragged from Preview, or an image dragged out of a web page.
        let content = ShelfDropReader.resolve(
            fileURLs: [], hasImage: true, richTextPlain: nil, plainText: nil
        )
        XCTAssertEqual(content, .image)
    }

    func testRichTextBeatsPlainText() {
        // Styled text dragged from a document offers both; keeping the styling is the better guess.
        let content = ShelfDropReader.resolve(
            fileURLs: [], hasImage: false, richTextPlain: "Hello", plainText: "Hello"
        )
        XCTAssertEqual(content, .richText(plain: "Hello"))
    }

    func testPlainTextIsTheLastResort() {
        let content = ShelfDropReader.resolve(
            fileURLs: [], hasImage: false, richTextPlain: nil, plainText: "just words"
        )
        XCTAssertEqual(content, .text("just words"))
    }

    func testTheFullOrderingIsFilesThenImageThenRichThenPlain() {
        // All four present at once: files must win.
        XCTAssertEqual(
            ShelfDropReader.resolve(
                fileURLs: [URL(fileURLWithPath: "/tmp/a")],
                hasImage: true, richTextPlain: "x", plainText: "y"
            ),
            .files([URL(fileURLWithPath: "/tmp/a")])
        )
    }

    // MARK: - Nothing usable

    func testAnEmptyDropIsRefused() {
        XCTAssertEqual(
            ShelfDropReader.resolve(fileURLs: [], hasImage: false, richTextPlain: nil, plainText: nil),
            .nothingUsable
        )
    }

    func testWhitespaceOnlyTextIsRefused() {
        // Dragging a stray selection of spaces onto the shelf should park nothing rather than an
        // invisible row.
        for text in ["", "   ", "\n\n", "\t "] {
            XCTAssertEqual(
                ShelfDropReader.resolve(
                    fileURLs: [], hasImage: false, richTextPlain: nil, plainText: text
                ),
                .nothingUsable,
                "‘\(text.debugDescription)’ should be refused"
            )
        }
    }

    func testEmptyRichTextFallsThroughRatherThanParkingNothing() {
        let content = ShelfDropReader.resolve(
            fileURLs: [], hasImage: false, richTextPlain: "", plainText: "real text"
        )
        XCTAssertEqual(content, .text("real text"))
    }

    // MARK: - Several files stay together

    func testMultipleFilesAreOneContent() {
        let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        XCTAssertEqual(
            ShelfDropReader.resolve(fileURLs: urls, hasImage: false, richTextPlain: nil, plainText: nil),
            .files(urls)
        )
    }
}
