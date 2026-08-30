import XCTest
@testable import Sarvkrit

final class RenamePatternTests: XCTestCase {
    private let modified = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_800_000_000)      // 2027-01-15 UTC

    private func context(
        name: String = "invoice",
        ext: String = "pdf",
        kind: FileKind = .document,
        captures: [String] = [],
        counter: Int = 1
    ) -> RenamePattern.Context {
        RenamePattern.Context(
            file: FileSnapshot(
                url: URL(fileURLWithPath: "/tmp/\(name).\(ext)"),
                name: name,
                fileExtension: ext,
                fullName: "\(name).\(ext)",
                kind: kind,
                size: 1,
                dateAdded: modified,
                dateModified: modified,
                sourceURL: nil,
                tags: [],
                isDirectory: false
            ),
            regexCaptures: captures,
            counter: counter,
            now: now
        )
    }

    func testPlainTokens() {
        XCTAssertEqual(RenamePattern.expand("{name}.{ext}", context: context()), "invoice.pdf")
        XCTAssertEqual(RenamePattern.expand("{fullname}", context: context()), "invoice.pdf")
        XCTAssertEqual(RenamePattern.expand("{kind}", context: context()), "Document")
        XCTAssertEqual(RenamePattern.expand("{name}-{counter}", context: context(counter: 3)), "invoice-3")
    }

    func testTokensAreCaseInsensitive() {
        XCTAssertEqual(RenamePattern.expand("{NAME}.{Ext}", context: context()), "invoice.pdf")
    }

    func testLiteralTextIsPreserved() {
        XCTAssertEqual(RenamePattern.expand("Scan - {name}", context: context()), "Scan - invoice")
        XCTAssertEqual(RenamePattern.expand("no tokens here", context: context()), "no tokens here")
        XCTAssertEqual(RenamePattern.expand("", context: context()), "")
    }

    func testDateFormatting() {
        XCTAssertEqual(RenamePattern.expand("{date:yyyy-MM-dd}", context: context()), "2026-01-01")
        XCTAssertEqual(RenamePattern.expand("{date:yyyy}/{date:MM}", context: context()), "2026/01")
        XCTAssertEqual(RenamePattern.expand("{now:yyyy}", context: context()), "2027")
    }

    func testRegexCapturesAreOneBased() {
        let ctx = context(captures: ["ACME", "042"])
        XCTAssertEqual(RenamePattern.expand("{match:1}-{match:2}", context: ctx), "ACME-042")
    }

    func testOutOfRangeCaptureIsLeftVerbatim() {
        // Visible breakage beats a silently empty filename.
        XCTAssertEqual(RenamePattern.expand("{match:9}", context: context(captures: ["a"])), "{match:9}")
        XCTAssertEqual(RenamePattern.expand("{match:0}", context: context(captures: ["a"])), "{match:0}")
    }

    func testUnknownTokenIsLeftVerbatimRatherThanDropped() {
        // A typo'd {nmae} should be visible in the result, not vanish.
        XCTAssertEqual(RenamePattern.expand("{nmae}.{ext}", context: context()), "{nmae}.pdf")
    }

    func testUnbalancedBraceDoesNotEatTheRest() {
        XCTAssertEqual(RenamePattern.expand("{name", context: context()), "{name")
        XCTAssertEqual(RenamePattern.expand("a{name}b{ext", context: context()), "ainvoiceb{ext")
    }

    func testSubfolderPatternsMayContainSeparators() {
        // sortIntoSubfolder shares this expander, so a path is a legitimate result.
        XCTAssertEqual(
            RenamePattern.expand("{date:yyyy}/{kind}", context: context()),
            "2026/Document"
        )
    }

    // MARK: - Sanitising

    func testSanitizeStripsPathSeparators() {
        // Without this an expanded token could escape its destination directory.
        XCTAssertEqual(RenamePattern.sanitizeComponent("a/b"), "a-b")
        XCTAssertEqual(RenamePattern.sanitizeComponent("a:b"), "a-b")
    }

    func testSanitizeRejectsNamesThatResolveToDirectories() {
        XCTAssertEqual(RenamePattern.sanitizeComponent("."), "untitled")
        XCTAssertEqual(RenamePattern.sanitizeComponent(".."), "untitled")
        XCTAssertEqual(RenamePattern.sanitizeComponent("   "), "untitled")
        XCTAssertEqual(RenamePattern.sanitizeComponent(""), "untitled")
    }

    func testSanitizeKeepsOrdinaryNames() {
        XCTAssertEqual(RenamePattern.sanitizeComponent("Invoice 2026 (final).pdf"), "Invoice 2026 (final).pdf")
    }

    func testDateFormattingIgnoresUserLocale() {
        // A rule filing into "2026-08" must not become non-Latin digits on someone's machine, or
        // the folder structure fragments per user.
        let expanded = RenamePattern.expand("{date:yyyy-MM}", context: context())
        XCTAssertEqual(expanded, "2026-01")
        XCTAssertTrue(expanded.allSatisfy { $0.isASCII })
    }
}
