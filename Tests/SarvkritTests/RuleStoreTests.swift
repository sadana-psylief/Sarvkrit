import XCTest
@testable import Sarvkrit

final class RuleStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-rules-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testAFreshInstallGetsExampleRules() {
        let store = RuleStore(directory: directory)
        XCTAssertFalse(store.rules.isEmpty, "an empty Files pane would look broken")
    }

    func testExampleRulesShipDisabled() {
        // Nothing should start moving a user's files because they flipped a switch to see what
        // the feature did.
        for rule in RuleStore.exampleRules() {
            XCTAssertFalse(rule.isEnabled, "“\(rule.name)” ships armed")
        }
    }

    func testRulesRoundTripThroughDisk() {
        let store = RuleStore(directory: directory)
        let rule = Rule(
            name: "Round trip",
            isEnabled: true,
            matchMode: .any,
            conditions: [Condition(attribute: .size, comparison: .isGreaterThan, value: .number(1_024))],
            actions: [.rename(pattern: "{name}-{counter}.{ext}"), .addTag("Big")]
        )
        store.replace(with: [rule])

        let reloaded = RuleStore(directory: directory)
        XCTAssertEqual(reloaded.rules, [rule])
    }

    func testEveryActionAndConditionValueSurvivesEncoding() throws {
        // Action and ConditionValue both carry associated values; a bad Codable conformance would
        // corrupt rules silently on the next launch.
        let rule = Rule(
            name: "All shapes",
            conditions: [
                Condition(attribute: .kind, comparison: .isExactly, value: .kind(.image)),
                Condition(attribute: .dateAdded, comparison: .isInLastDays, value: .days(7)),
                Condition(attribute: .dateModified, comparison: .isBefore, value: .date(Date(timeIntervalSince1970: 1))),
                Condition(attribute: .name, comparison: .contains, value: .text("x")),
                Condition(attribute: .size, comparison: .isLessThan, value: .number(5)),
            ],
            actions: [
                .move(destinationBookmark: Data([1, 2, 3])),
                .copy(destinationBookmark: Data([4])),
                .rename(pattern: "{name}"),
                .sortIntoSubfolder(pattern: "{kind}"),
                .addTag("t"),
                .setColorLabel(.red),
                .moveToTrash,
                .notify(message: "done"),
            ]
        )

        let data = try JSONEncoder().encode([rule])
        XCTAssertEqual(try JSONDecoder().decode([Rule].self, from: data), [rule])
    }

    func testAnUnreadableFileIsNotSilentlyReplaced() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "this is not json".write(
            to: directory.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)

        let store = RuleStore(directory: directory)

        // Empty, not examples: the file is the user's automation, and overwriting it with defaults
        // would destroy work they can still recover by hand.
        XCTAssertTrue(store.rules.isEmpty)
        let onDisk = try String(contentsOf: directory.appendingPathComponent("rules.json"), encoding: .utf8)
        XCTAssertEqual(onDisk, "this is not json", "the unreadable file must be left alone")
    }
}
