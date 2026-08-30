import XCTest
@testable import Sarvkrit

final class ClipboardCapturePolicyTests: XCTestCase {
    private var settings = ClipboardSettings()

    private func snapshot(
        files: [String] = [],
        directories: Set<String> = [],
        imageBytes: Int? = nil,
        rtfBytes: Int? = nil,
        text: String? = nil
    ) -> ClipboardCapturePolicy.Snapshot {
        ClipboardCapturePolicy.Snapshot(
            types: ["public.utf8-plain-text"],
            filePaths: files,
            directoryPaths: directories,
            imageByteCount: imageBytes,
            imageWidth: imageBytes == nil ? 0 : 100,
            imageHeight: imageBytes == nil ? 0 : 100,
            richTextByteCount: rtfBytes,
            plainText: text
        )
    }

    // MARK: - Resolution order

    func testAFileCopyBecomesFilesNotTheFilenameAsText() {
        // The trap. Copying a file in Finder ALSO puts a plain-text representation of the filename
        // on the pasteboard. Checking text first records the string "report.pdf" instead of the
        // file — the feature looks like it works and does the wrong thing.
        let outcome = ClipboardCapturePolicy.outcome(
            for: snapshot(files: ["/tmp/report.pdf"], text: "report.pdf"),
            settings: settings
        )
        XCTAssertEqual(outcome, .files(["/tmp/report.pdf"]))
    }

    func testAnImageWithATextRepresentationBecomesAnImage() {
        let outcome = ClipboardCapturePolicy.outcome(
            for: snapshot(imageBytes: 5_000, text: "Screenshot"), settings: settings)
        XCTAssertEqual(outcome, .image(byteCount: 5_000, width: 100, height: 100))
    }

    func testRichTextIsPreferredOverPlainText() {
        let outcome = ClipboardCapturePolicy.outcome(
            for: snapshot(rtfBytes: 900, text: "styled"), settings: settings)
        XCTAssertEqual(outcome, .richText(plain: "styled"))
    }

    func testPlainTextIsTheFallback() {
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(text: "hello"), settings: settings),
            .text("hello"))
    }

    func testAnEmptyPasteboardIsSkipped() {
        XCTAssertEqual(ClipboardCapturePolicy.outcome(for: snapshot(), settings: settings), .skip(.empty))
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(text: ""), settings: settings), .skip(.empty))
    }

    // MARK: - Per-kind toggles

    func testEachKindCanBeTurnedOffIndependently() {
        settings.storeFiles = false
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(files: ["/tmp/a"]), settings: settings),
            .skip(.kindDisabled))

        settings = ClipboardSettings()
        settings.storeImages = false
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(imageBytes: 10), settings: settings),
            .skip(.kindDisabled))

        settings = ClipboardSettings()
        settings.storeText = false
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(text: "x"), settings: settings),
            .skip(.kindDisabled))
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(rtfBytes: 10, text: "x"), settings: settings),
            .skip(.kindDisabled))
    }

    // MARK: - The folder rule

    func testWithNoLimitSetAFolderCopyIsSkipped() {
        // The user's rule: a folder stands for an unbounded amount of data, so it needs a
        // deliberate opt-in.
        settings.maxItemSizeMB = 0
        let outcome = ClipboardCapturePolicy.outcome(
            for: snapshot(files: ["/tmp/folder"], directories: ["/tmp/folder"]),
            settings: settings)
        XCTAssertEqual(outcome, .skip(.containsFolder))
    }

    func testWithNoLimitSetIndividualFilesAreStillKept() {
        settings.maxItemSizeMB = 0
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(files: ["/tmp/a.txt"]), settings: settings),
            .files(["/tmp/a.txt"]))
    }

    func testAMixedSelectionContainingAFolderIsSkippedWithNoLimit() {
        settings.maxItemSizeMB = 0
        let outcome = ClipboardCapturePolicy.outcome(
            for: snapshot(files: ["/tmp/a.txt", "/tmp/folder"], directories: ["/tmp/folder"]),
            settings: settings)
        XCTAssertEqual(outcome, .skip(.containsFolder))
    }

    func testWithALimitSetFoldersAreAllowed() {
        settings.maxItemSizeMB = 50
        let outcome = ClipboardCapturePolicy.outcome(
            for: snapshot(files: ["/tmp/folder"], directories: ["/tmp/folder"]),
            settings: settings)
        XCTAssertEqual(outcome, .files(["/tmp/folder"]))
    }

    // MARK: - Size limit

    func testOversizedImagesAndTextAreSkipped() {
        settings.maxItemSizeMB = 1
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(imageBytes: 2_097_152), settings: settings),
            .skip(.tooLarge))
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(
                for: snapshot(text: String(repeating: "x", count: 2_097_152)), settings: settings),
            .skip(.tooLarge))
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(
                for: snapshot(rtfBytes: 2_097_152, text: "x"), settings: settings),
            .skip(.tooLarge))
    }

    func testItemsUnderTheLimitAreKept() {
        settings.maxItemSizeMB = 1
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(imageBytes: 1_000), settings: settings),
            .image(byteCount: 1_000, width: 100, height: 100))
    }

    func testFileSizeIsNotCheckedBecauseOnlyThePathIsStored() {
        // A 4GB video costs the same as a text file here — the point of storing references.
        settings.maxItemSizeMB = 1
        XCTAssertEqual(
            ClipboardCapturePolicy.outcome(for: snapshot(files: ["/tmp/huge.mov"]), settings: settings),
            .files(["/tmp/huge.mov"]))
    }

    // MARK: - Inline ceiling

    func testHugeTextSpillsToAFileEvenWithNoUserLimit() {
        // Independent of the user's setting: a multi-megabyte paste inside clipboard.json would
        // slow every launch.
        XCTAssertTrue(ClipboardCapturePolicy.shouldSpillToFile(
            String(repeating: "x", count: ClipboardCapturePolicy.inlineTextCeiling + 1)))
        XCTAssertFalse(ClipboardCapturePolicy.shouldSpillToFile("short"))
    }
}
