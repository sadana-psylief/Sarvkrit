import XCTest
@testable import Sarvkrit

final class ClipboardSearchTests: XCTestCase {

    private func ranges(_ query: String, _ text: String, _ mode: ClipboardSearch.Mode) -> [String] {
        guard let match = ClipboardSearch.match(query: query, in: text, mode: mode) else { return [] }
        return match.ranges.map { String(text[$0]) }
    }

    // MARK: - Exact

    func testExactIsCaseAndDiacriticInsensitiveSubstring() {
        XCTAssertNotNil(ClipboardSearch.match(query: "WORLD", in: "hello world", mode: .exact))
        XCTAssertNotNil(ClipboardSearch.match(query: "cafe", in: "café au lait", mode: .exact))
        XCTAssertNil(ClipboardSearch.match(query: "wrold", in: "hello world", mode: .exact))
    }

    func testExactHighlightsExactlyTheMatch() {
        XCTAssertEqual(ranges("wor", "hello world", .exact), ["wor"])
    }

    func testExactRanksEarlierMatchesHigher() {
        let early = ClipboardSearch.match(query: "a", in: "apple", mode: .exact)!
        let late = ClipboardSearch.match(query: "a", in: "zzzzzzzzzza", mode: .exact)!
        XCTAssertGreaterThan(early.score, late.score)
    }

    // MARK: - Fuzzy

    func testFuzzyFindsASubsequence() {
        // The headline case.
        XCTAssertNotNil(ClipboardSearch.match(query: "invpdf", in: "invoice-2026.pdf", mode: .fuzzy))
        XCTAssertNotNil(ClipboardSearch.match(query: "hw", in: "hello world", mode: .fuzzy))
    }

    func testFuzzyRejectsAnythingThatIsNotASubsequence() {
        // Order matters — otherwise "fuzzy" would match essentially everything.
        XCTAssertNil(ClipboardSearch.match(query: "dfp", in: "invoice.pdf", mode: .fuzzy))
        XCTAssertNil(ClipboardSearch.match(query: "xyz", in: "invoice.pdf", mode: .fuzzy))
    }

    func testFuzzyPrefersContiguousMatches() {
        let contiguous = ClipboardSearch.match(query: "inv", in: "invoice", mode: .fuzzy)!
        let scattered = ClipboardSearch.match(query: "inv", in: "i-n-v-x-y-z", mode: .fuzzy)!
        XCTAssertGreaterThan(contiguous.score, scattered.score,
                             "a run of adjacent characters should outrank scattered ones")
    }

    func testFuzzyPrefersWordStarts() {
        let atStart = ClipboardSearch.match(query: "r", in: "report", mode: .fuzzy)!
        let midWord = ClipboardSearch.match(query: "r", in: "bureau", mode: .fuzzy)!
        XCTAssertGreaterThan(atStart.score, midWord.score)
    }

    func testFuzzyMergesAdjacentRangesIntoOneSpan() {
        // Otherwise "inv" would render as three separate bold letters rather than one word.
        XCTAssertEqual(ranges("inv", "invoice", .fuzzy), ["inv"])
    }

    func testFuzzyHighlightsEachMatchedCharacter() {
        XCTAssertEqual(ranges("hw", "hello world", .fuzzy), ["h", "w"])
    }

    // MARK: - Ranges stay valid

    func testRangesAreValidForMultiByteText() {
        // An out-of-range highlight would crash the row it's drawn in.
        let text = "café — naïve 🎉 done"
        for mode in ClipboardSearch.Mode.allCases {
            guard let match = ClipboardSearch.match(query: "done", in: text, mode: mode) else {
                return XCTFail("\(mode) failed to match")
            }
            for range in match.ranges {
                XCTAssertTrue(text.indices.contains(range.lowerBound))
                XCTAssertLessThanOrEqual(range.upperBound, text.endIndex)
            }
            XCTAssertEqual(match.ranges.map { String(text[$0]) }.joined(), "done")
        }
    }

    func testAnEmptyQueryMatchesEverythingWithNoHighlight() {
        for mode in ClipboardSearch.Mode.allCases {
            let match = ClipboardSearch.match(query: "  ", in: "anything", mode: mode)
            XCTAssertEqual(match?.ranges.count, 0)
        }
    }

    // MARK: - Sorting

    private func item(_ text: String, last: TimeInterval, first: TimeInterval, count: Int, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(
            kind: .text(text),
            createdAt: Date(timeIntervalSince1970: last),
            firstCopiedAt: Date(timeIntervalSince1970: first),
            copyCount: count,
            isPinned: pinned
        )
    }

    func testEachSortModeOrdersDifferently() {
        let items = [
            item("A", last: 300, first: 100, count: 1),
            item("B", last: 200, first: 50, count: 9),
            item("C", last: 100, first: 400, count: 5),
        ]
        XCTAssertEqual(items.sorted(by: .lastCopy, pinned: .top).map(\.searchableText), ["A", "B", "C"])
        XCTAssertEqual(items.sorted(by: .firstCopy, pinned: .top).map(\.searchableText), ["C", "A", "B"])
        XCTAssertEqual(items.sorted(by: .copyCount, pinned: .top).map(\.searchableText), ["B", "C", "A"])
    }

    func testEqualCopyCountsFallBackToRecency() {
        // Otherwise equal-count entries shuffle on every redraw.
        let items = [
            item("older", last: 100, first: 100, count: 3),
            item("newer", last: 200, first: 200, count: 3),
        ]
        XCTAssertEqual(items.sorted(by: .copyCount, pinned: .top).map(\.searchableText), ["newer", "older"])
    }

    func testPinnedItemsGroupTopOrBottom() {
        let items = [
            item("loose", last: 300, first: 300, count: 1),
            item("pinned", last: 100, first: 100, count: 1, pinned: true),
        ]
        XCTAssertEqual(items.sorted(by: .lastCopy, pinned: .top).map(\.searchableText), ["pinned", "loose"])
        XCTAssertEqual(items.sorted(by: .lastCopy, pinned: .bottom).map(\.searchableText), ["loose", "pinned"])
    }
}
