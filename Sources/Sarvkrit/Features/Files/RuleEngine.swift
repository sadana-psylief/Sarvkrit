import Foundation
import os

/// Puts one file through the rules: snapshot it, decide whether it's safe to touch, find the first
/// matching rule, run that rule's actions, and record that it happened.
///
/// The safety checks are the reason this is a type rather than a free function. Three things must
/// hold before a single byte moves, and each has bitten every tool in this category:
/// the file must have finished being written, the same rule must not already have handled it, and
/// nothing may be permanently deleted.
final class RuleEngine {
    /// What happened to one file, for the log and for the dry-run preview.
    struct Report: Equatable {
        enum Verdict: Equatable {
            case noMatch
            case skippedUnstable
            case skippedAlreadyProcessed(ruleName: String)
            case acted(ruleName: String, summaries: [String])
            case failed(ruleName: String, reason: String)
        }

        var url: URL
        var verdict: Verdict
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "FileRules")
    private let runner: ActionRunner
    private var stability = FileStabilityTracker()

    init(runner: ActionRunner = ActionRunner()) {
        self.runner = runner
    }

    /// `enforceStability` is off for dry runs and for the initial sweep of a folder, where files
    /// have plainly been sitting there for a while and there's no second event coming to confirm.
    func process(
        url: URL,
        rules: [Rule],
        mode: ActionRunner.Mode,
        now: Date = Date(),
        enforceStability: Bool = true
    ) -> Report {
        guard let file = FileInspector.snapshot(of: url) else {
            return Report(url: url, verdict: .noMatch)
        }

        if enforceStability, mode == .perform {
            guard stability.isStable(url, sample: FileStabilityTracker.sample(of: file)) else {
                return Report(url: url, verdict: .skippedUnstable)
            }
        }

        guard let rule = RuleMatcher.firstMatch(for: file, in: rules, now: now) else {
            return Report(url: url, verdict: .noMatch)
        }

        // The loop guard. Checked after matching so the log can name the rule that would have run.
        let lastMatch = ProcessedMarker.read(at: url)
        if ProcessedMarker.shouldSkip(lastMatch: lastMatch, ruleID: rule.id, fileModified: file.dateModified) {
            return Report(url: url, verdict: .skippedAlreadyProcessed(ruleName: rule.name))
        }

        let captures = self.captures(for: file, rule: rule)

        // Marked *before* acting: a move changes the path, and the xattr has to be on the file
        // while we still know where it is. It travels with the file.
        if mode == .perform {
            ProcessedMarker.write(.init(ruleID: rule.id, date: now), at: url)
        }

        let results = runner.run(rule.actions, on: file, captures: captures, mode: mode, now: now)

        var summaries: [String] = []
        for result in results {
            switch result {
            case .success(let outcome):
                summaries.append(outcome.summary)
            case .failure(let error):
                log.error("rule “\(rule.name, privacy: .public)” failed: \(String(describing: error), privacy: .public)")
                return Report(url: url, verdict: .failed(ruleName: rule.name, reason: String(describing: error)))
            }
        }

        if mode == .perform {
            stability.forget(url)
            log.info("rule “\(rule.name, privacy: .public)” ran on \(file.fullName, privacy: .public)")
        }
        return Report(url: url, verdict: .acted(ruleName: rule.name, summaries: summaries))
    }

    /// Everything currently in a folder, one pass. Used for the initial sweep when a rule is turned
    /// on, and for the dry-run preview.
    func processFolder(
        _ folder: URL,
        rules: [Rule],
        mode: ActionRunner.Mode,
        now: Date = Date()
    ) -> [Report] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { process(url: $0, rules: rules, mode: mode, now: now, enforceStability: false) }
    }

    /// Capture groups from the rule's first regex condition, so `{match:1}` in a rename pattern has
    /// something to draw on.
    private func captures(for file: FileSnapshot, rule: Rule) -> [String] {
        for condition in rule.conditions where condition.comparison == .matchesRegex {
            guard case .text(let pattern) = condition.value,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            let subject: String
            switch condition.attribute {
            case .name: subject = file.name
            case .fullName: subject = file.fullName
            case .fileExtension: subject = file.fileExtension
            default: continue
            }

            let range = NSRange(subject.startIndex..., in: subject)
            guard let match = regex.firstMatch(in: subject, options: [], range: range) else { continue }

            return (1..<match.numberOfRanges).compactMap { index in
                guard let r = Range(match.range(at: index), in: subject) else { return nil }
                return String(subject[r])
            }
        }
        return []
    }
}
