import XCTest
@testable import Sarvkrit

/// The decision core for text expansion, and — more importantly — the place the privacy guarantees
/// are checkable rather than merely asserted in a comment.
final class SnippetMatcherTests: XCTestCase {

    private func matcher(_ snippets: [Snippet]) -> SnippetMatcher {
        var matcher = SnippetMatcher()
        matcher.setSnippets(snippets)
        return matcher
    }

    /// Types a whole string, returning the last decision.
    private func type(_ text: String, into matcher: inout SnippetMatcher) -> SnippetMatcher.Decision {
        var last = SnippetMatcher.Decision.ignore
        for character in text {
            last = matcher.typed(character)
        }
        return last
    }

    private func expansion(of decision: SnippetMatcher.Decision) -> String? {
        guard case .expand(_, _, let text) = decision else { return nil }
        return text
    }

    private func deleteCount(of decision: SnippetMatcher.Decision) -> Int? {
        guard case .expand(_, let count, _) = decision else { return nil }
        return count
    }

    // MARK: - Prefix style

    func testAPrefixTriggerFiresAsSoonAsItIsComplete() {
        var m = matcher([Snippet(trigger: ";addr", expansion: "221B Baker Street", style: .prefix)])
        let decision = type(";addr", into: &m)
        XCTAssertEqual(expansion(of: decision), "221B Baker Street")
        XCTAssertEqual(deleteCount(of: decision), 5, "the five typed characters come back out")
    }

    func testAPartialPrefixTriggerDoesNothing() {
        var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        XCTAssertEqual(type(";add", into: &m), .ignore)
    }

    func testAPrefixTriggerFiresMidWord() {
        // The marker is what makes this safe: nothing types `;addr` by accident, so there is no
        // reason to wait for a boundary.
        var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        XCTAssertNotNil(expansion(of: type("see;addr", into: &m)))
    }

    func testTheLongestOverlappingTriggerWins() {
        // With both `;a` and `;ab`, the short one would fire on the way to the long one and the
        // long one could never be reached.
        var m = matcher([
            Snippet(trigger: ";a", expansion: "SHORT", style: .prefix),
            Snippet(trigger: ";ab", expansion: "LONG", style: .prefix),
        ])
        _ = m.typed(";")
        XCTAssertEqual(expansion(of: m.typed("a")), "SHORT", "`;a` is complete on its own")

        var fresh = matcher([
            Snippet(trigger: ";xa", expansion: "SHORT", style: .prefix),
            Snippet(trigger: "yxa", expansion: "LONG", style: .prefix),
        ])
        // Buffer ends with both triggers; the longer must be preferred.
        XCTAssertEqual(expansion(of: type("yxa", into: &fresh)), "LONG")
    }

    // MARK: - Word-boundary style

    func testAWordBoundaryTriggerWaitsForTheDelimiter() {
        var m = matcher([Snippet(trigger: "addr", expansion: "221B", style: .wordBoundary)])
        XCTAssertEqual(type("addr", into: &m), .ignore, "not yet — no boundary")
        XCTAssertEqual(expansion(of: m.typed(" ")), "221B ", "the space is given back")
    }

    func testTheDelimiterIsCountedInWhatGetsDeleted() {
        var m = matcher([Snippet(trigger: "addr", expansion: "221B", style: .wordBoundary)])
        _ = type("addr", into: &m)
        XCTAssertEqual(deleteCount(of: m.typed(" ")), 5, "four characters plus the space")
    }

    func testAWordBoundaryTriggerDoesNotFireInsideALongerWord() {
        // The whole reason this style exists.
        var m = matcher([Snippet(trigger: "addr", expansion: "221B", style: .wordBoundary)])
        _ = type("myaddr", into: &m)
        XCTAssertEqual(m.typed(" "), .ignore, "`addr` here is the tail of `myaddr`")
    }

    func testPunctuationCountsAsABoundary() {
        // People type `addr,` and `addr.` as readily as `addr `.
        for delimiter in [",", ".", "!", ")", "\n", "\t"] {
            var m = matcher([Snippet(trigger: "addr", expansion: "221B", style: .wordBoundary)])
            _ = type("addr", into: &m)
            XCTAssertNotNil(expansion(of: m.typed(Character(delimiter))),
                            "‘\(delimiter)’ should end the word")
        }
    }

    func testAPrefixTriggerIsNotFiredByADelimiter() {
        var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        _ = type(";add", into: &m)
        XCTAssertEqual(m.typed(" "), .ignore)
    }

    // MARK: - The buffer: privacy, structurally

    func testTheBufferNeverExceedsItsCap() {
        // The guarantee that matters. Not "we promise not to read a sentence" — it cannot hold one.
        var m = matcher([Snippet(trigger: ";ab", expansion: "X", style: .prefix)])
        for character in "correct horse battery staple hunter2" {
            _ = m.typed(character)
            XCTAssertLessThanOrEqual(m.buffer.count, m.capacity)
        }
        // Trigger length plus two: one for the delimiter a word-boundary trigger completes on, one
        // for the left context that tells `addr ` from `myaddr `.
        XCTAssertEqual(m.capacity, 5)
    }

    func testTheCapIsTightAgainstTheLongestTrigger() {
        // Guards against the cap quietly growing later — it is a privacy bound, not a buffer size.
        for length in 1...12 {
            var m = matcher([
                Snippet(trigger: String(repeating: "a", count: length), expansion: "X", style: .prefix)
            ])
            XCTAssertEqual(m.capacity, length + 2)
            _ = type(String(repeating: "b", count: 60), into: &m)
            XCTAssertLessThanOrEqual(m.buffer.count, length + 2)
        }
    }

    func testEveryInterruptionEmptiesTheBuffer() {
        let reasons: [SnippetMatcher.Interruption] =
            [.appChanged, .caretMoved, .modifierChord, .idle, .secureInput]
        for reason in reasons {
            var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
            _ = type(";ad", into: &m)
            XCTAssertFalse(m.buffer.isEmpty, "precondition")
            m.interrupt(reason)
            XCTAssertTrue(m.buffer.isEmpty, "\(reason) must clear the buffer")
        }
    }

    func testADelimiterStaysInTheBufferRatherThanClearingIt() {
        // Two reasons it must not clear. `;` is itself punctuation, so clearing on delimiters meant
        // a `;addr` trigger could never accumulate at all — and a word-boundary trigger needs the
        // preceding character to know whether it is a word of its own.
        var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        _ = type("hel ", into: &m)
        XCTAssertFalse(m.buffer.isEmpty)
        XCTAssertLessThanOrEqual(m.buffer.count, m.capacity, "still bounded, just not cleared")
    }

    func testTheMarkerCharacterCanStartATrigger() {
        // The bug this guards: `;` is punctuation, and treating punctuation as a hard delimiter
        // made every recommended trigger style impossible to type.
        for marker in [";", ":", "/", "\\", ",", "."] {
            var m = matcher([Snippet(trigger: "\(marker)hi", expansion: "HELLO", style: .prefix)])
            XCTAssertEqual(expansion(of: type("\(marker)hi", into: &m)), "HELLO",
                           "‘\(marker)’ should be usable as a trigger marker")
        }
    }

    func testExpandingClearsTheBuffer() {
        // The typed trigger is about to be deleted, so holding it would double-fire on the next key.
        var m = matcher([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
        _ = type(";a", into: &m)
        XCTAssertTrue(m.buffer.isEmpty)
    }

    func testAWordBoundaryTriggerFiresAfterAPrecedingWord() {
        // `addr ` at the start fires; so must `hello addr `, where a space precedes the trigger.
        var m = matcher([Snippet(trigger: "addr", expansion: "221B", style: .wordBoundary)])
        _ = type("hello addr", into: &m)
        XCTAssertEqual(expansion(of: m.typed(" ")), "221B ")
    }

    func testAnInterruptionMidTriggerPreventsTheExpansion() {
        var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        _ = type(";add", into: &m)
        m.interrupt(.caretMoved)
        XCTAssertEqual(m.typed("r"), .ignore, "the trigger was broken by the caret moving")
    }

    func testNothingIsHeldWhenThereAreNoSnippets() {
        // With an empty table the capacity is zero, so the feature holds nothing at all even while
        // enabled.
        var m = matcher([])
        _ = type("some private sentence", into: &m)
        XCTAssertTrue(m.buffer.isEmpty)
        XCTAssertEqual(m.capacity, 0)
    }

    func testShrinkingTheTableShrinksTheBuffer() {
        var m = matcher([Snippet(trigger: ";averylongtrigger", expansion: "X", style: .prefix)])
        _ = type(";averylongtrig", into: &m)
        XCTAssertFalse(m.buffer.isEmpty, "precondition")

        m.setSnippets([Snippet(trigger: ";a", expansion: "X", style: .prefix)])
        XCTAssertEqual(m.capacity, 4, "two-character trigger plus the delimiter and left context")
        XCTAssertLessThanOrEqual(m.buffer.count, m.capacity,
                                 "the old buffer must be trimmed to the new, smaller cap")
    }

    func testANilCharacterNeitherAppendsNorClears() {
        // A bare modifier press types nothing but doesn't move the caret either.
        var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        _ = type(";ad", into: &m)
        let before = m.buffer
        XCTAssertEqual(m.typed(nil), .ignore)
        XCTAssertEqual(m.buffer, before)
    }

    // MARK: - Which snippets count

    func testDisabledSnippetsNeverFire() {
        var m = matcher([
            Snippet(trigger: ";off", expansion: "X", style: .prefix, isEnabled: false)
        ])
        XCTAssertEqual(type(";off", into: &m), .ignore)
        XCTAssertEqual(m.capacity, 0, "a disabled snippet shouldn't even widen the buffer")
    }

    func testInvalidSnippetsNeverFire() {
        // An expansion that starts with its own trigger would re-match on the next keystroke.
        var m = matcher([Snippet(trigger: ";a", expansion: ";ab", style: .prefix)])
        XCTAssertEqual(type(";a", into: &m), .ignore)
    }

    func testCaseMattersInATrigger() {
        var m = matcher([Snippet(trigger: ";addr", expansion: "X", style: .prefix)])
        XCTAssertEqual(type(";ADDR", into: &m), .ignore)
    }

    // MARK: - Tokens run at expansion time

    func testTokensAreExpandedWhenTheTriggerFires() {
        var m = matcher([Snippet(trigger: ";d", expansion: "{date:yyyy}", style: .prefix)])
        let context = SnippetPattern.Context(
            now: Date(timeIntervalSince1970: 1_777_000_000),
            locale: Locale(identifier: "en_US_POSIX"),
            calendar: Calendar(identifier: .gregorian)
        )
        _ = m.typed(";", context: context)
        XCTAssertEqual(expansion(of: m.typed("d", context: context)), "2026")
    }
}
