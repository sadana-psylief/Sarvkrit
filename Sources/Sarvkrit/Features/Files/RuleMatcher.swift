import Foundation

/// Decides whether a file matches a rule. Entirely pure — no disk, no clock, no side effects —
/// so the whole condition vocabulary is table-testable.
///
/// `now` is injected rather than read from `Date()` so relative conditions ("added in the last 7
/// days") are deterministic in tests.
enum RuleMatcher {
    static func matches(_ file: FileSnapshot, rule: Rule, now: Date = Date()) -> Bool {
        guard rule.isEnabled else { return false }
        // A rule with no conditions matches nothing. The alternative — matching everything — turns
        // a half-built rule in the editor into an accident involving every file in the folder.
        guard !rule.conditions.isEmpty else { return false }

        switch rule.matchMode {
        case .all:
            return rule.conditions.allSatisfy { matches(file, condition: $0, now: now) }
        case .any:
            return rule.conditions.contains { matches(file, condition: $0, now: now) }
        }
    }

    /// The first rule that matches, or nil. Ordering is semantic: Hazel runs only the first
    /// matching rule, and reproducing that is what makes rule order mean something.
    static func firstMatch(for file: FileSnapshot, in rules: [Rule], now: Date = Date()) -> Rule? {
        rules.first { matches(file, rule: $0, now: now) }
    }

    static func matches(_ file: FileSnapshot, condition: Condition, now: Date = Date()) -> Bool {
        switch condition.attribute {
        case .name:
            return compareText(file.name, condition)
        case .fileExtension:
            return compareText(file.fileExtension, condition)
        case .fullName:
            return compareText(file.fullName, condition)
        case .sourceURL:
            // No recorded origin can't satisfy a positive test, but "does not contain" should
            // still hold — otherwise rules about downloads would quietly skip local files.
            return compareText(file.sourceURL ?? "", condition, treatingEmptyAsAbsent: file.sourceURL == nil)
        case .tags:
            return compareTags(file.tags, condition)
        case .kind:
            guard case .kind(let wanted) = condition.value else { return false }
            switch condition.comparison {
            case .isExactly: return file.kind == wanted
            case .isNot: return file.kind != wanted
            default: return false
            }
        case .size:
            guard case .number(let wanted) = condition.value else { return false }
            switch condition.comparison {
            case .isGreaterThan: return file.size > wanted
            case .isLessThan: return file.size < wanted
            case .isExactly: return file.size == wanted
            case .isNot: return file.size != wanted
            default: return false
            }
        case .dateAdded:
            return compareDate(file.dateAdded, condition, now: now)
        case .dateModified:
            return compareDate(file.dateModified, condition, now: now)
        }
    }

    // MARK: - Per-type comparisons

    private static func compareText(
        _ subject: String,
        _ condition: Condition,
        treatingEmptyAsAbsent isAbsent: Bool = false
    ) -> Bool {
        guard case .text(let wanted) = condition.value else { return false }

        // Case-insensitive throughout: filenames on macOS are case-insensitive by default, so a
        // case-sensitive rule would surprise people.
        let subjectFolded = subject.lowercased()
        let wantedFolded = wanted.lowercased()

        switch condition.comparison {
        case .isExactly: return !isAbsent && subjectFolded == wantedFolded
        case .isNot: return isAbsent || subjectFolded != wantedFolded
        case .contains: return !isAbsent && subjectFolded.contains(wantedFolded)
        case .doesNotContain: return isAbsent || !subjectFolded.contains(wantedFolded)
        case .beginsWith: return !isAbsent && subjectFolded.hasPrefix(wantedFolded)
        case .endsWith: return !isAbsent && subjectFolded.hasSuffix(wantedFolded)
        case .matchesRegex:
            guard !isAbsent,
                  let regex = try? NSRegularExpression(pattern: wanted, options: [.caseInsensitive])
            else { return false }
            let range = NSRange(subject.startIndex..., in: subject)
            return regex.firstMatch(in: subject, options: [], range: range) != nil
        default:
            return false
        }
    }

    private static func compareTags(_ tags: [String], _ condition: Condition) -> Bool {
        guard case .text(let wanted) = condition.value else { return false }
        let folded = tags.map { $0.lowercased() }
        let target = wanted.lowercased()
        switch condition.comparison {
        case .isExactly, .contains: return folded.contains(target)
        case .isNot, .doesNotContain: return !folded.contains(target)
        default: return false
        }
    }

    private static func compareDate(_ subject: Date, _ condition: Condition, now: Date) -> Bool {
        switch (condition.comparison, condition.value) {
        case (.isBefore, .date(let wanted)): return subject < wanted
        case (.isAfter, .date(let wanted)): return subject > wanted
        case (.isInLastDays, .days(let days)):
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
                return false
            }
            return subject >= cutoff
        default:
            return false
        }
    }
}
