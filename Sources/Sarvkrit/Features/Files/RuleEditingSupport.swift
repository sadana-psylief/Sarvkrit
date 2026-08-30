import Foundation

/// What the editor is allowed to offer for each attribute.
///
/// Pure lookup tables rather than logic scattered through the views, so "a size condition can never
/// be given a date" is a property the tests can assert rather than something the UI is trusted to
/// get right.
extension Attribute {
    /// Operators that mean something for this attribute. Offering `isGreaterThan` on a filename, or
    /// `contains` on a size, would build rules that silently never match.
    var supportedOperators: [ComparisonOperator] {
        switch self {
        case .name, .fileExtension, .fullName, .sourceURL:
            return [.isExactly, .isNot, .contains, .doesNotContain, .beginsWith, .endsWith, .matchesRegex]
        case .tags:
            return [.contains, .doesNotContain]
        case .kind:
            return [.isExactly, .isNot]
        case .size:
            return [.isGreaterThan, .isLessThan, .isExactly, .isNot]
        case .dateAdded, .dateModified:
            return [.isInLastDays, .isBefore, .isAfter]
        }
    }

    /// The value editor this attribute needs.
    var valueKind: ValueKind {
        switch self {
        case .name, .fileExtension, .fullName, .sourceURL, .tags: return .text
        case .kind: return .kind
        case .size: return .bytes
        case .dateAdded, .dateModified: return .date
        }
    }

    enum ValueKind {
        case text, bytes, date, kind
    }

    /// A value of the right shape, used when the user switches an existing condition to a different
    /// attribute — otherwise the old value would linger and the condition would stop matching.
    func defaultValue(for comparison: ComparisonOperator) -> ConditionValue {
        switch valueKind {
        case .text: return .text("")
        case .bytes: return .number(1_048_576)
        case .kind: return .kind(.document)
        case .date: return comparison == .isInLastDays ? .days(7) : .date(Date())
        }
    }
}

extension ComparisonOperator {
    var title: String {
        switch self {
        case .isExactly: return "is"
        case .isNot: return "is not"
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .beginsWith: return "begins with"
        case .endsWith: return "ends with"
        case .matchesRegex: return "matches regex"
        case .isBefore: return "is before"
        case .isAfter: return "is after"
        case .isInLastDays: return "is in the last"
        case .isGreaterThan: return "is greater than"
        case .isLessThan: return "is less than"
        }
    }
}

extension Condition {
    /// Re-points a condition at a new attribute, repairing the operator and value so the result is
    /// always coherent. The editor calls this instead of assigning `attribute` directly.
    func retargeted(to attribute: Attribute) -> Condition {
        guard attribute != self.attribute else { return self }
        let comparison = attribute.supportedOperators.contains(self.comparison)
            ? self.comparison
            : (attribute.supportedOperators.first ?? .isExactly)
        return Condition(
            id: id,
            attribute: attribute,
            comparison: comparison,
            value: attribute.defaultValue(for: comparison)
        )
    }

    /// Changing the operator can change the value's shape too — "is in the last" wants a day count
    /// where "is before" wants a date.
    func withComparison(_ comparison: ComparisonOperator) -> Condition {
        var updated = self
        updated.comparison = comparison
        if attribute.valueKind == .date {
            let wantsDays = comparison == .isInLastDays
            let hasDays = { if case .days = value { return true } else { return false } }()
            if wantsDays != hasDays {
                updated.value = attribute.defaultValue(for: comparison)
            }
        }
        return updated
    }
}

extension Action {
    var title: String {
        switch self {
        case .move: return "Move to folder"
        case .copy: return "Copy to folder"
        case .rename: return "Rename"
        case .sortIntoSubfolder: return "Sort into subfolder"
        case .addTag: return "Add tag"
        case .setColorLabel: return "Set colour label"
        case .moveToTrash: return "Move to Trash"
        case .notify: return "Notify"
        }
    }

    /// Every action in its default form, for the editor's "add action" menu.
    static var allTemplates: [Action] {
        [
            .sortIntoSubfolder(pattern: "{kind}"),
            .rename(pattern: "{name}.{ext}"),
            .move(destinationBookmark: Data()),
            .copy(destinationBookmark: Data()),
            .addTag(""),
            .setColorLabel(.none),
            .moveToTrash,
            .notify(message: "{fullname} was filed"),
        ]
    }

    /// Actions needing a folder chosen before they can run. A rule carrying one of these with an
    /// empty bookmark is incomplete, and the editor says so rather than failing at match time.
    var needsDestinationFolder: Bool {
        switch self {
        case .move(let data), .copy(let data): return data.isEmpty
        default: return false
        }
    }
}

extension ColorLabel {
    var title: String {
        switch self {
        case .none: return "None"
        case .gray: return "Grey"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }
}

extension Rule {
    /// Why this rule can't run yet, if it can't. Shown in the editor so a half-built rule is
    /// visibly incomplete instead of quietly never matching.
    var validationProblem: String? {
        if folderBookmark == nil { return "Choose a folder to watch" }
        if conditions.isEmpty { return "Add at least one condition" }
        if actions.isEmpty { return "Add at least one action" }
        if actions.contains(where: \.needsDestinationFolder) { return "Choose a destination folder" }
        return nil
    }

    var isRunnable: Bool { validationProblem == nil }
}
