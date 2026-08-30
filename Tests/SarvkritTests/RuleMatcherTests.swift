import XCTest
@testable import Sarvkrit

final class RuleMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(
        name: String = "invoice",
        ext: String = "pdf",
        kind: FileKind = .document,
        size: Int64 = 1_000,
        dateAdded: Date? = nil,
        dateModified: Date? = nil,
        sourceURL: String? = nil,
        tags: [String] = []
    ) -> FileSnapshot {
        FileSnapshot(
            url: URL(fileURLWithPath: "/tmp/\(name).\(ext)"),
            name: name,
            fileExtension: ext,
            fullName: "\(name).\(ext)",
            kind: kind,
            size: size,
            dateAdded: dateAdded ?? now,
            dateModified: dateModified ?? now,
            sourceURL: sourceURL,
            tags: tags,
            isDirectory: false
        )
    }

    private func condition(_ a: Attribute, _ c: ComparisonOperator, _ v: ConditionValue) -> Condition {
        Condition(attribute: a, comparison: c, value: v)
    }

    private func rule(
        _ conditions: [Condition],
        mode: MatchMode = .all,
        enabled: Bool = true
    ) -> Rule {
        Rule(name: "test", isEnabled: enabled, matchMode: mode, conditions: conditions)
    }

    // MARK: - Text

    func testTextOperators() {
        let f = file(name: "Invoice-2026", ext: "pdf")
        let cases: [(ComparisonOperator, String, Bool)] = [
            (.isExactly, "invoice-2026", true),
            (.isExactly, "invoice", false),
            (.isNot, "something", true),
            (.contains, "voice", true),
            (.contains, "zzz", false),
            (.doesNotContain, "zzz", true),
            (.beginsWith, "inv", true),
            (.beginsWith, "2026", false),
            (.endsWith, "2026", true),
            (.matchesRegex, #"^invoice-\d{4}$"#, true),
            (.matchesRegex, #"^\d+$"#, false),
        ]
        for (op, value, expected) in cases {
            let matched = RuleMatcher.matches(f, condition: condition(.name, op, .text(value)), now: now)
            XCTAssertEqual(matched, expected, "\(op) '\(value)'")
        }
    }

    func testMatchingIsCaseInsensitive() {
        // macOS filenames are case-insensitive by default; a case-sensitive rule would surprise.
        let f = file(name: "Screenshot")
        XCTAssertTrue(RuleMatcher.matches(f, condition: condition(.name, .isExactly, .text("SCREENSHOT")), now: now))
        XCTAssertTrue(RuleMatcher.matches(f, condition: condition(.name, .contains, .text("SHOT")), now: now))
    }

    func testInvalidRegexDoesNotMatchRatherThanCrashing() {
        let f = file(name: "anything")
        let bad = condition(.name, .matchesRegex, .text("[unclosed"))
        XCTAssertFalse(RuleMatcher.matches(f, condition: bad, now: now))
    }

    // MARK: - Source URL absence

    func testMissingSourceURLFailsPositiveTestsButSatisfiesNegativeOnes() {
        // A local file has no recorded origin. "Doesn't come from example.com" is true of it —
        // treating absence as a non-match on both sides would silently skip local files.
        let local = file(sourceURL: nil)
        XCTAssertFalse(RuleMatcher.matches(local, condition: condition(.sourceURL, .contains, .text("example.com")), now: now))
        XCTAssertTrue(RuleMatcher.matches(local, condition: condition(.sourceURL, .doesNotContain, .text("example.com")), now: now))

        let downloaded = file(sourceURL: "https://example.com/a.pdf")
        XCTAssertTrue(RuleMatcher.matches(downloaded, condition: condition(.sourceURL, .contains, .text("example.com")), now: now))
    }

    // MARK: - Size, kind, tags

    func testSizeComparisons() {
        let f = file(size: 5_000)
        XCTAssertTrue(RuleMatcher.matches(f, condition: condition(.size, .isGreaterThan, .number(1_000)), now: now))
        XCTAssertFalse(RuleMatcher.matches(f, condition: condition(.size, .isGreaterThan, .number(9_000)), now: now))
        XCTAssertTrue(RuleMatcher.matches(f, condition: condition(.size, .isLessThan, .number(9_000)), now: now))
    }

    func testKindAndTags() {
        XCTAssertTrue(RuleMatcher.matches(file(kind: .image), condition: condition(.kind, .isExactly, .kind(.image)), now: now))
        XCTAssertTrue(RuleMatcher.matches(file(kind: .image), condition: condition(.kind, .isNot, .kind(.video)), now: now))
        XCTAssertTrue(RuleMatcher.matches(file(tags: ["Work"]), condition: condition(.tags, .contains, .text("work")), now: now))
        XCTAssertTrue(RuleMatcher.matches(file(tags: []), condition: condition(.tags, .doesNotContain, .text("work")), now: now))
    }

    func testMismatchedValueTypeNeverMatches() {
        // A size condition holding text is a corrupt rule; it must decline rather than coerce.
        let broken = condition(.size, .isGreaterThan, .text("big"))
        XCTAssertFalse(RuleMatcher.matches(file(), condition: broken, now: now))
    }

    // MARK: - Dates

    func testRelativeDatesUseInjectedNow() {
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let twentyDaysAgo = now.addingTimeInterval(-20 * 86_400)

        let recent = condition(.dateAdded, .isInLastDays, .days(7))
        XCTAssertTrue(RuleMatcher.matches(file(dateAdded: threeDaysAgo), condition: recent, now: now))
        XCTAssertFalse(RuleMatcher.matches(file(dateAdded: twentyDaysAgo), condition: recent, now: now))
    }

    func testAbsoluteDateComparisons() {
        let old = file(dateModified: now.addingTimeInterval(-86_400))
        XCTAssertTrue(RuleMatcher.matches(old, condition: condition(.dateModified, .isBefore, .date(now)), now: now))
        XCTAssertFalse(RuleMatcher.matches(old, condition: condition(.dateModified, .isAfter, .date(now)), now: now))
    }

    // MARK: - Rule level

    func testAllVersusAny() {
        let f = file(name: "invoice", ext: "pdf")
        let matching = condition(.fileExtension, .isExactly, .text("pdf"))
        let failing = condition(.name, .isExactly, .text("nope"))

        XCTAssertFalse(RuleMatcher.matches(f, rule: rule([matching, failing], mode: .all), now: now))
        XCTAssertTrue(RuleMatcher.matches(f, rule: rule([matching, failing], mode: .any), now: now))
        XCTAssertTrue(RuleMatcher.matches(f, rule: rule([matching], mode: .all), now: now))
    }

    func testRuleWithNoConditionsMatchesNothing() {
        // Matching everything would turn a half-written rule in the editor into an accident
        // involving every file in the folder.
        XCTAssertFalse(RuleMatcher.matches(file(), rule: rule([]), now: now))
    }

    func testDisabledRuleNeverMatches() {
        let always = condition(.fileExtension, .isExactly, .text("pdf"))
        XCTAssertFalse(RuleMatcher.matches(file(), rule: rule([always], enabled: false), now: now))
    }

    // MARK: - Ordering

    func testFirstMatchWins() {
        // Hazel's model, and the reason rule order is semantic rather than cosmetic.
        let first = Rule(name: "first", conditions: [condition(.fileExtension, .isExactly, .text("pdf"))])
        let second = Rule(name: "second", conditions: [condition(.kind, .isExactly, .kind(.document))])

        let winner = RuleMatcher.firstMatch(for: file(), in: [first, second], now: now)
        XCTAssertEqual(winner?.name, "first")

        let reversed = RuleMatcher.firstMatch(for: file(), in: [second, first], now: now)
        XCTAssertEqual(reversed?.name, "second")
    }

    func testDisabledRulesAreSkippedWhenFindingTheFirstMatch() {
        let disabled = Rule(name: "disabled", isEnabled: false,
                            conditions: [condition(.fileExtension, .isExactly, .text("pdf"))])
        let enabled = Rule(name: "enabled",
                           conditions: [condition(.kind, .isExactly, .kind(.document))])
        XCTAssertEqual(RuleMatcher.firstMatch(for: file(), in: [disabled, enabled], now: now)?.name, "enabled")
    }

    func testNoMatchReturnsNil() {
        let rules = [Rule(name: "x", conditions: [condition(.fileExtension, .isExactly, .text("zip"))])]
        XCTAssertNil(RuleMatcher.firstMatch(for: file(), in: rules, now: now))
    }
}
