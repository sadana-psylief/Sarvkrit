import XCTest
@testable import Sarvkrit

/// End-to-end against a real temp directory. These cover the three safety properties that decide
/// whether a rules engine is trustworthy: it must not loop, it must not touch files still being
/// written, and a dry run must change nothing.
final class RuleEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ name: String, contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    private func sortRule(_ name: String = "sort", pattern: String = "Sorted") -> Rule {
        Rule(
            name: name,
            conditions: [Condition(attribute: .fileExtension, comparison: .isExactly, value: .text("txt"))],
            actions: [.sortIntoSubfolder(pattern: pattern)]
        )
    }

    // MARK: - Loop prevention

    func testARuleThatMovesIntoItsOwnWatchedFolderRunsOnce() throws {
        // The canonical loop: the move fires a filesystem event, the file matches again, it moves
        // again — forever. The marker is what stops it.
        let file = try makeFile("a.txt")
        let engine = RuleEngine()
        let rule = sortRule()

        let first = engine.process(url: file, rules: [rule], mode: .perform, enforceStability: false)
        guard case .acted = first.verdict else { return XCTFail("first pass should act: \(first.verdict)") }
        XCTAssertTrue(exists("Sorted/a.txt"))

        // Feed the moved file back in, exactly as a filesystem event would.
        let moved = root.appendingPathComponent("Sorted/a.txt")
        let second = engine.process(url: moved, rules: [rule], mode: .perform, enforceStability: false)

        guard case .skippedAlreadyProcessed = second.verdict else {
            return XCTFail("second pass must be skipped, got \(second.verdict)")
        }
        XCTAssertFalse(exists("Sorted/Sorted/a.txt"), "the rule looped")
    }

    func testADifferentRuleMayStillActOnAnAlreadyProcessedFile() throws {
        // Chaining rules is legitimate; the guard is per-rule, not per-file.
        let file = try makeFile("a.txt")
        let engine = RuleEngine()

        _ = engine.process(url: file, rules: [sortRule("first")], mode: .perform, enforceStability: false)
        let moved = root.appendingPathComponent("Sorted/a.txt")

        let other = Rule(
            name: "second",
            conditions: [Condition(attribute: .fileExtension, comparison: .isExactly, value: .text("txt"))],
            actions: [.addTag("Seen")]
        )
        let report = engine.process(url: moved, rules: [other], mode: .perform, enforceStability: false)

        guard case .acted = report.verdict else { return XCTFail("expected the second rule to act") }
    }

    func testAFileModifiedAfterItsLastMatchIsProcessedAgain() {
        // Pure decision check: new work on a file that already matched should not be locked out.
        let ruleID = UUID()
        let matchedAt = Date(timeIntervalSince1970: 1_000)
        let record = ProcessedMarker.Record(ruleID: ruleID, date: matchedAt)

        XCTAssertTrue(ProcessedMarker.shouldSkip(
            lastMatch: record, ruleID: ruleID, fileModified: matchedAt.addingTimeInterval(-10)))
        XCTAssertFalse(ProcessedMarker.shouldSkip(
            lastMatch: record, ruleID: ruleID, fileModified: matchedAt.addingTimeInterval(10)))
        XCTAssertFalse(ProcessedMarker.shouldSkip(
            lastMatch: record, ruleID: UUID(), fileModified: matchedAt))
        XCTAssertFalse(ProcessedMarker.shouldSkip(
            lastMatch: nil, ruleID: ruleID, fileModified: matchedAt))
    }

    func testTheMarkerSurvivesBeingWrittenAndReadBack() throws {
        let file = try makeFile("a.txt")
        let record = ProcessedMarker.Record(ruleID: UUID(), date: Date(timeIntervalSince1970: 5_000))

        XCTAssertTrue(ProcessedMarker.write(record, at: file))
        XCTAssertEqual(ProcessedMarker.read(at: file), record)
    }

    // MARK: - Stability

    func testAFileStillGrowingIsNotActedOn() throws {
        // A download in progress: filing it mid-transfer leaves a truncated file in the wrong place.
        let file = try makeFile("download.txt", contents: "partial")
        let engine = RuleEngine()

        let first = engine.process(url: file, rules: [sortRule()], mode: .perform)
        XCTAssertEqual(first.verdict, .skippedUnstable, "first sighting has nothing to compare against")
        XCTAssertFalse(exists("Sorted/download.txt"))

        // It grew — still not settled.
        try "partial plus more".data(using: .utf8)!.write(to: file)
        let second = engine.process(url: file, rules: [sortRule()], mode: .perform)
        XCTAssertEqual(second.verdict, .skippedUnstable)
        XCTAssertFalse(exists("Sorted/download.txt"))

        // Unchanged since the last look — now it's safe.
        let third = engine.process(url: file, rules: [sortRule()], mode: .perform)
        guard case .acted = third.verdict else { return XCTFail("a settled file should act: \(third.verdict)") }
        XCTAssertTrue(exists("Sorted/download.txt"))
    }

    func testStabilityTrackerNeedsTwoMatchingSamples() {
        var tracker = FileStabilityTracker()
        let url = URL(fileURLWithPath: "/tmp/x")
        let a = FileStabilityTracker.Sample(size: 10, modified: Date(timeIntervalSince1970: 1))
        let b = FileStabilityTracker.Sample(size: 20, modified: Date(timeIntervalSince1970: 2))

        XCTAssertFalse(tracker.isStable(url, sample: a), "first sighting is never stable")
        XCTAssertTrue(tracker.isStable(url, sample: a))
        XCTAssertFalse(tracker.isStable(url, sample: b), "it changed")
        XCTAssertTrue(tracker.isStable(url, sample: b))
    }

    // MARK: - Matching and ordering

    func testOnlyTheFirstMatchingRuleRuns() throws {
        let file = try makeFile("a.txt")
        let first = sortRule("first", pattern: "First")
        let second = sortRule("second", pattern: "Second")

        let report = RuleEngine().process(url: file, rules: [first, second], mode: .perform, enforceStability: false)

        guard case .acted(let ruleName, _) = report.verdict else { return XCTFail("expected action") }
        XCTAssertEqual(ruleName, "first")
        XCTAssertTrue(exists("First/a.txt"))
        XCTAssertFalse(exists("Second/a.txt"))
    }

    func testNoMatchLeavesTheFileAlone() throws {
        let file = try makeFile("a.png")
        let report = RuleEngine().process(url: file, rules: [sortRule()], mode: .perform, enforceStability: false)

        XCTAssertEqual(report.verdict, .noMatch)
        XCTAssertTrue(exists("a.png"))
    }

    func testRegexCapturesReachRenamePatterns() throws {
        let file = try makeFile("Invoice-ACME-042.txt")
        let rule = Rule(
            name: "extract",
            conditions: [Condition(
                attribute: .name,
                comparison: .matchesRegex,
                value: .text(#"^Invoice-(\w+)-(\d+)$"#)
            )],
            actions: [.rename(pattern: "{match:2} {match:1}.{ext}")]
        )

        let report = RuleEngine().process(url: file, rules: [rule], mode: .perform, enforceStability: false)

        guard case .acted = report.verdict else { return XCTFail("expected action: \(report.verdict)") }
        XCTAssertTrue(exists("042 ACME.txt"))
    }

    // MARK: - Folder sweep and preview

    func testProcessFolderHandlesEveryFile() throws {
        try makeFile("a.txt")
        try makeFile("b.txt")
        try makeFile("c.png")

        let reports = RuleEngine().processFolder(root, rules: [sortRule()], mode: .perform)

        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(exists("Sorted/a.txt"))
        XCTAssertTrue(exists("Sorted/b.txt"))
        XCTAssertTrue(exists("c.png"), "a non-matching file stays put")
    }

    func testDryRunOverAFolderChangesNothing() throws {
        try makeFile("a.txt")
        try makeFile("b.txt")

        let reports = RuleEngine().processFolder(root, rules: [sortRule()], mode: .dryRun)

        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(exists("a.txt"))
        XCTAssertTrue(exists("b.txt"))
        XCTAssertFalse(exists("Sorted"), "a preview must not create anything")

        // …and it still reports what it would have done.
        guard case .acted(_, let summaries) = reports[0].verdict else { return XCTFail("expected a preview") }
        XCTAssertFalse(summaries.isEmpty)
    }

    func testDryRunDoesNotWriteTheProcessedMarker() throws {
        // Otherwise previewing a rule would prevent it ever actually running.
        let file = try makeFile("a.txt")
        _ = RuleEngine().process(url: file, rules: [sortRule()], mode: .dryRun, enforceStability: false)
        XCTAssertNil(ProcessedMarker.read(at: file))
    }
}
