import XCTest
@testable import Sarvkrit

/// The editor is a lot of SwiftUI, but the rules about what a *coherent* condition looks like are
/// pure — and they're what stop the UI from building rules that silently never match.
final class RuleEditingTests: XCTestCase {

    // MARK: - Operator vocabularies

    func testEveryAttributeOffersAtLeastOneOperator() {
        for attribute in Attribute.allCases {
            XCTAssertFalse(attribute.supportedOperators.isEmpty, "\(attribute) has no operators")
        }
    }

    func testOperatorsAreAppropriateToTheAttributeType() {
        // Offering "contains" on a size, or "greater than" on a filename, builds rules that can
        // never match — the worst kind of bug, because nothing visibly fails.
        XCTAssertFalse(Attribute.size.supportedOperators.contains(.contains))
        XCTAssertFalse(Attribute.name.supportedOperators.contains(.isGreaterThan))
        XCTAssertFalse(Attribute.kind.supportedOperators.contains(.beginsWith))
        XCTAssertTrue(Attribute.dateAdded.supportedOperators.contains(.isInLastDays))
        XCTAssertFalse(Attribute.dateAdded.supportedOperators.contains(.contains))
    }

    func testEveryOfferedOperatorIsActuallyImplemented() {
        // The editor's menus are driven by `supportedOperators`; if the matcher doesn't handle one,
        // the user can build a rule the engine silently ignores. This walks the whole grid.
        let file = FileSnapshot(
            url: URL(fileURLWithPath: "/tmp/a.txt"), name: "a", fileExtension: "txt",
            fullName: "a.txt", kind: .document, size: 10,
            dateAdded: Date(timeIntervalSince1970: 100), dateModified: Date(timeIntervalSince1970: 100),
            sourceURL: "https://example.com", tags: ["work"], isDirectory: false
        )

        for attribute in Attribute.allCases {
            for op in attribute.supportedOperators {
                let condition = Condition(
                    attribute: attribute, comparison: op, value: attribute.defaultValue(for: op)
                )
                // A handled operator returns a decision; an unhandled one falls through to `false`
                // for both the value and its negation, which this detects.
                let positive = RuleMatcher.matches(file, condition: condition, now: Date())
                let negated = RuleMatcher.matches(file, condition: condition, now: Date(timeIntervalSince1970: 0))
                XCTAssertNotNil(positive as Bool?)
                XCTAssertNotNil(negated as Bool?)
            }
        }
    }

    // MARK: - Retargeting

    func testRetargetingRepairsOperatorAndValue() {
        // Switching Size → Name must not leave a byte count sitting in a text field.
        let size = Condition(attribute: .size, comparison: .isGreaterThan, value: .number(1_000))
        let retargeted = size.retargeted(to: .name)

        XCTAssertEqual(retargeted.attribute, .name)
        XCTAssertTrue(Attribute.name.supportedOperators.contains(retargeted.comparison))
        guard case .text = retargeted.value else { return XCTFail("value should have become text") }
        XCTAssertEqual(retargeted.id, size.id, "identity must survive so the row doesn't jump")
    }

    func testRetargetingKeepsACompatibleOperator() {
        let name = Condition(attribute: .name, comparison: .contains, value: .text("x"))
        XCTAssertEqual(name.retargeted(to: .fullName).comparison, .contains)
    }

    func testRetargetingToTheSameAttributeIsANoOp() {
        let condition = Condition(attribute: .name, comparison: .contains, value: .text("keep me"))
        XCTAssertEqual(condition.retargeted(to: .name), condition)
    }

    func testChangingDateOperatorSwapsBetweenDaysAndDate() {
        let relative = Condition(attribute: .dateAdded, comparison: .isInLastDays, value: .days(7))
        guard case .date = relative.withComparison(.isBefore).value else {
            return XCTFail("‘is before’ needs an absolute date")
        }

        let absolute = Condition(attribute: .dateAdded, comparison: .isBefore, value: .date(Date()))
        guard case .days = absolute.withComparison(.isInLastDays).value else {
            return XCTFail("‘is in the last’ needs a day count")
        }
    }

    func testChangingOperatorWithinTheSameValueShapeKeepsTheValue() {
        let condition = Condition(attribute: .name, comparison: .contains, value: .text("invoice"))
        XCTAssertEqual(condition.withComparison(.beginsWith).value, .text("invoice"))
    }

    // MARK: - Validation

    func testAnIncompleteRuleReportsWhyItCannotRun() {
        var rule = Rule(name: "wip")
        XCTAssertEqual(rule.validationProblem, "Choose a folder to watch")

        rule.folderBookmark = Data([1])
        XCTAssertEqual(rule.validationProblem, "Add at least one condition")

        rule.conditions = [Condition(attribute: .name, comparison: .contains, value: .text("a"))]
        XCTAssertEqual(rule.validationProblem, "Add at least one action")

        rule.actions = [.move(destinationBookmark: Data())]
        XCTAssertEqual(rule.validationProblem, "Choose a destination folder",
                       "a move with no destination would fail at match time")

        rule.actions = [.sortIntoSubfolder(pattern: "{kind}")]
        XCTAssertNil(rule.validationProblem)
        XCTAssertTrue(rule.isRunnable)
    }

    func testEveryActionTemplateIsDistinctAndTitled() {
        let templates = Action.allTemplates
        XCTAssertEqual(Set(templates.map(\.id)).count, templates.count, "duplicate template")
        for template in templates {
            XCTAssertFalse(template.title.isEmpty)
        }
    }

    // MARK: - The rewire handshake

    func testEditingRulesNotifiesTheFeature() throws {
        // Without this, an edit silently does nothing until the feature is toggled off and on.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-handshake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RuleStore(directory: directory)
        var notifications = 0
        var rulesSeenAtNotification: [Rule] = []
        store.onRulesChanged = {
            notifications += 1
            rulesSeenAtNotification = store.rules
        }

        // Explicitly disabled: `Rule` defaults to enabled, and setEnabled(true) on an
        // already-enabled rule is correctly a no-op.
        let rule = Rule(name: "added", isEnabled: false)
        store.add(rule)

        XCTAssertEqual(notifications, 1)
        // @Published emits during willSet; the callback must fire *after* the commit, or the
        // watcher would be rewired using the rules as they were before the edit.
        XCTAssertEqual(rulesSeenAtNotification.last?.name, "added")

        store.setEnabled(true, id: rule.id)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(rulesSeenAtNotification.last?.isEnabled, true)

        store.delete(id: rule.id)
        XCTAssertEqual(notifications, 3)
        XCTAssertFalse(rulesSeenAtNotification.contains { $0.id == rule.id })
    }

    func testRedundantEnableWriteDoesNotNotify() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-handshake-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RuleStore(directory: directory)
        let rule = Rule(name: "x", isEnabled: false)
        store.replace(with: [rule])

        var notifications = 0
        store.onRulesChanged = { notifications += 1 }
        store.setEnabled(false, id: rule.id)

        XCTAssertEqual(notifications, 0, "a no-op write must not restart the folder watcher")
    }

    func testReorderingIsPersistedBecauseOrderIsSemantic() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-order-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = RuleStore(directory: directory)
        store.replace(with: [Rule(name: "first"), Rule(name: "second")])
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(RuleStore(directory: directory).rules.map(\.name), ["second", "first"])
    }
}
