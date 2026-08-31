import XCTest
@testable import Sarvkrit

/// The snippet token grammar, which deliberately mirrors `RenamePattern`'s so the app teaches one
/// token language rather than two that almost match.
final class SnippetPatternTests: XCTestCase {

    /// Fixed so the tests don't depend on the machine's region. Production uses `.current`, which is
    /// the whole point — see the note on `Context.locale`.
    private func context(_ timestamp: TimeInterval = 1_777_000_000) -> SnippetPattern.Context {
        SnippetPattern.Context(
            now: Date(timeIntervalSince1970: timestamp),
            locale: Locale(identifier: "en_US_POSIX"),
            calendar: Calendar(identifier: .gregorian)
        )
    }

    // MARK: - Literal text

    func testTextWithNoTokensIsUntouched() {
        XCTAssertEqual(SnippetPattern.expand("Best,\nTushar", context: context()), "Best,\nTushar")
    }

    func testEmptyPatternExpandsToEmpty() {
        XCTAssertEqual(SnippetPattern.expand("", context: context()), "")
    }

    // MARK: - Tokens

    func testFormattedDateToken() {
        XCTAssertEqual(SnippetPattern.expand("{date:yyyy-MM-dd}", context: context()), "2026-04-24")
    }

    func testFormattedNowToken() {
        // Same formatter as `{date:}` — `{now:}` reads better when the format includes a time.
        let expanded = SnippetPattern.expand("{now:yyyy}", context: context())
        XCTAssertEqual(expanded, "2026")
    }

    func testTokensCanBeEmbeddedInText() {
        XCTAssertEqual(
            SnippetPattern.expand("Filed on {date:yyyy-MM-dd}.", context: context()),
            "Filed on 2026-04-24."
        )
    }

    func testSeveralTokensInOnePattern() {
        XCTAssertEqual(
            SnippetPattern.expand("{date:yyyy}/{date:MM}", context: context()),
            "2026/04"
        )
    }

    func testBareTokensUseTheSystemStyles() {
        // The bare forms deliberately don't pin a format — they should read the way dates do
        // everywhere else on the user's Mac.
        XCTAssertFalse(SnippetPattern.expand("{date}", context: context()).isEmpty)
        XCTAssertFalse(SnippetPattern.expand("{time}", context: context()).isEmpty)
        XCTAssertFalse(SnippetPattern.expand("{now}", context: context()).isEmpty)
        XCTAssertNotEqual(SnippetPattern.expand("{date}", context: context()), "{date}")
    }

    func testTokenNamesAreCaseInsensitive() {
        XCTAssertEqual(SnippetPattern.expand("{DATE:yyyy}", context: context()), "2026")
    }

    // MARK: - Malformed input, which must stay visible

    func testAnUnknownTokenIsLeftVerbatim() {
        // Same rule as RenamePattern: a typo should be visible in what got typed, because silently
        // expanding to nothing is far harder to diagnose.
        XCTAssertEqual(SnippetPattern.expand("{dat:yyyy}", context: context()), "{dat:yyyy}")
        XCTAssertEqual(SnippetPattern.expand("{nonsense}", context: context()), "{nonsense}")
    }

    func testAnUnbalancedBraceIsEmittedAsLiteralText() {
        XCTAssertEqual(SnippetPattern.expand("a {date:yyyy", context: context()), "a {date:yyyy")
    }

    func testAnUnknownTokenAmongGoodOnesDoesNotBreakTheRest() {
        XCTAssertEqual(
            SnippetPattern.expand("{date:yyyy} {oops} {date:MM}", context: context()),
            "2026 {oops} 04"
        )
    }

    func testEmptyBracesAreLeftVerbatim() {
        XCTAssertEqual(SnippetPattern.expand("{}", context: context()), "{}")
    }

    // MARK: - Locale

    func testTheOutputFollowsTheGivenLocale() {
        // Where snippets deliberately differ from RenamePattern, which pins en_US_POSIX so a folder
        // name can't fragment across regions. A snippet is prose a person is about to send.
        let french = SnippetPattern.Context(
            now: Date(timeIntervalSince1970: 1_777_000_000),
            locale: Locale(identifier: "fr_FR"),
            calendar: Calendar(identifier: .gregorian)
        )
        let english = context()

        XCTAssertEqual(SnippetPattern.expand("{date:MMMM}", context: english), "April")
        XCTAssertEqual(SnippetPattern.expand("{date:MMMM}", context: french), "avril")
    }

    // MARK: - isDynamic, which drives the editor's preview

    func testAPatternWithADateTokenIsDynamic() {
        XCTAssertTrue(SnippetPattern.isDynamic("{date:yyyy-MM-dd}"))
        XCTAssertTrue(SnippetPattern.isDynamic("Filed {date}"))
    }

    func testAPlainPatternIsNotDynamic() {
        XCTAssertFalse(SnippetPattern.isDynamic("Best,\nTushar"))
        XCTAssertFalse(SnippetPattern.isDynamic("{unknown}"))
    }

    // MARK: - The documented list must actually work

    func testEveryDocumentedTokenExpands() {
        // A token offered in the editor that expands to itself would be a lie in the UI.
        for (token, _) in SnippetPattern.documentedTokens {
            let sample = token.replacingOccurrences(of: "FORMAT", with: "yyyy")
            XCTAssertNotEqual(SnippetPattern.expand(sample, context: context()), sample,
                              "\(token) is documented but doesn't expand")
        }
    }

    // MARK: - Shipped examples

    func testTheExampleSnippetsAreAllValidAndExpand() {
        for snippet in SnippetStore.exampleSnippets() {
            XCTAssertNil(snippet.validationProblem, "\(snippet.trigger) ships invalid")
            let expanded = SnippetPattern.expand(snippet.expansion, context: context())
            XCTAssertFalse(expanded.isEmpty, "\(snippet.trigger) expands to nothing")
            XCTAssertFalse(expanded.contains("{"), "\(snippet.trigger) leaves an unexpanded token")
        }
    }
}
