import Combine
import Foundation
import SwiftUI
import os

/// The Files category's rules engine, as a toggleable feature.
///
/// Conforms to `Feature` but not `EventTapFeature` — this is exactly the case the protocol split
/// existed for: it watches folders and never sees a keystroke.
final class FileRulesFeature: Feature, ObservableObject {
    let id = "file-rules"
    let category = FeatureCategory.files
    let title = "File Rules"
    let summary = "Sort and rename files automatically"
    let details = """
        Watches folders you choose and applies rules to files as they arrive — move them, rename \
        them with date and name patterns, sort them into subfolders, or tag them.

        Rules are checked in order and only the first one that matches a file runs, so the order \
        of your rules decides what happens. Nothing is ever deleted permanently: files Sarvkrit \
        removes go to the Trash.
        """
    let symbolName = "folder.badge.gearshape"

    /// No Accessibility needed. macOS prompts for folder access on first read instead, which is a
    /// separate grant with separate UI.
    let requirements: Set<Requirement> = []

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "FileRules")
    private let store: RuleStore
    private let engine: RuleEngine
    private lazy var watcher = FolderWatcher { [weak self] urls in
        self?.handleChanges(urls)
    }

    /// Shown as "Recent Activity". `@Published` because otherwise the pane renders whatever was
    /// true when it was built — a rule that IS working looks like it isn't.
    @Published private(set) var lastReports: [RuleEngine.Report] = []

    /// True between `activate()` and `deactivate()`. Needed so an edit made while the feature is
    /// off doesn't start a watcher behind the user's back.
    private var isActive = false

    private static let recheckInterval: TimeInterval = 1.2
    private static let maxRechecks = 5

    /// Everything below is touched **only** on `workQueue`.
    ///
    /// It used to be reachable from two queues at once: `handleChanges` arrives on the folder
    /// watcher's queue and mutated all three on the way through `scheduleRecheck`, while the
    /// recheck itself was dispatched to main and mutated them again. Unsynchronised `Set` and
    /// `Dictionary` access across two threads is a rare crash rather than a visible bug, which is
    /// the worst kind to leave in.
    private var recheckWorkItem: DispatchWorkItem?
    private var pendingRecheck: Set<URL> = []
    private var recheckAttempts: [URL: Int] = [:]

    /// Serialises the rule state, and keeps the engine off the main thread.
    ///
    /// The work here is not small — a stat and an extended-attribute read per file, a regex
    /// compiled per rule, and the file moves themselves. Running it on main also stalled the event
    /// tap, whose run loop is there.
    private let workQueue = DispatchQueue(label: "\(AppIdentity.bundleID).file-rules")

    init(store: RuleStore = RuleStore(), engine: RuleEngine = RuleEngine()) {
        self.store = store
        self.engine = engine

        // The rewire handshake. Editing a rule has to re-point the folder watcher, or changes
        // silently do nothing until the feature is toggled off and on — the same shape of bug as
        // granting Accessibility and having nothing happen until relaunch.
        store.onRulesChanged = { [weak self] in self?.rulesDidChange() }
    }

    private func rulesDidChange() {
        guard isActive else { return }
        watcher.stop()
        startWatching()
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(FileRulesDetailView(feature: self, store: store))
    }

    var rules: [Rule] { store.rules }

    func activate() {
        isActive = true
        startWatching()
    }

    func deactivate() {
        isActive = false
        watcher.stop()
        workQueue.async { [weak self] in
            guard let self else { return }
            self.recheckWorkItem?.cancel()
            self.recheckWorkItem = nil
            self.pendingRecheck.removeAll()
            self.recheckAttempts.removeAll()
        }
    }

    private func startWatching() {
        let folders = watchedFolders()
        guard !folders.isEmpty else {
            log.info("no runnable rules with a folder — nothing to watch")
            return
        }
        watcher.start(watching: folders)

        // Sweep what's already there. Stability is not enforced for this pass: these files have
        // plainly finished arriving, and there's no second event coming to confirm it.
        //
        // Off the main thread: this walks every watched folder and can move files, and it runs
        // whenever the feature activates or a rule is edited.
        let rules = runnableRules()
        workQueue.async { [weak self] in
            guard let self else { return }
            for folder in folders {
                self.record(self.engine.processFolder(folder, rules: rules, mode: .perform))
            }
        }
    }

    /// What a rule *would* do, changing nothing. This is the preview the editor is built on.
    ///
    /// The rule is evaluated **as if enabled**. You preview a rule precisely while building it, and
    /// a rule under construction is disabled — so asking the matcher about it as-is means being
    /// correctly told "no match" for every file, every time. The enabled check stays where it
    /// belongs, on the live path in `runnableRules()`.
    func preview(rule: Rule) -> [RuleEngine.Report] {
        guard let folder = folder(for: rule) else { return [] }
        var asIfEnabled = rule
        asIfEnabled.isEnabled = true
        return RuleEngine().processFolder(folder, rules: [asIfEnabled], mode: .dryRun)
    }

    private func handleChanges(_ urls: [URL]) {
        workQueue.async { [weak self] in self?.process(urls) }
    }

    @discardableResult
    private func process(_ urls: [URL]) -> [RuleEngine.Report] {
        let rules = runnableRules()
        guard !rules.isEmpty else { return [] }
        let reports = urls.map { engine.process(url: $0, rules: rules, mode: .perform) }
        record(reports)

        // A file that arrived once and never changed again produces exactly one filesystem event —
        // and the stability check correctly declines to touch it on first sight, because it has
        // nothing to compare against yet. Without a second look, that file would sit there
        // forever. So anything deferred as "still being written" gets re-examined shortly after,
        // which is also when a genuine download will have finished or visibly grown.
        let unsettled = reports.compactMap { $0.verdict == .skippedUnstable ? $0.url : nil }
        scheduleRecheck(of: unsettled)
        return reports
    }

    private func scheduleRecheck(of urls: [URL]) {
        guard !urls.isEmpty else { return }

        var worthRetrying: [URL] = []
        for url in urls {
            let attempts = recheckAttempts[url, default: 0]
            // Bounded: a file that never settles is being written continuously, and the next real
            // filesystem event will restart this anyway.
            guard attempts < Self.maxRechecks else {
                recheckAttempts.removeValue(forKey: url)
                continue
            }
            recheckAttempts[url] = attempts + 1
            worthRetrying.append(url)
        }
        guard !worthRetrying.isEmpty else { return }

        pendingRecheck.formUnion(worthRetrying)
        recheckWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runRecheck() }
        recheckWorkItem = work
        workQueue.asyncAfter(deadline: .now() + Self.recheckInterval, execute: work)
    }

    private func runRecheck() {
        let urls = Array(pendingRecheck)
        pendingRecheck.removeAll()
        guard !urls.isEmpty else { return }

        let reports = process(urls)
        // Anything that finally settled can stop being tracked.
        for report in reports where report.verdict != .skippedUnstable {
            recheckAttempts.removeValue(forKey: report.url)
        }
    }

    private func record(_ reports: [RuleEngine.Report]) {
        let interesting = reports.filter {
            if case .noMatch = $0.verdict { return false }
            if case .skippedUnstable = $0.verdict { return false }
            return true
        }
        guard !interesting.isEmpty else { return }
        // `lastReports` is @Published and drives the pane, so it is read *and* written on main —
        // reading it from the work queue while main writes would be the same race this file just
        // fixed elsewhere.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastReports = (interesting + self.lastReports).prefix(100).map { $0 }
        }
    }

    /// Enabled *and* complete. A rule missing a folder or an action would otherwise be matched
    /// against and then fail at action time, which is a worse way to find out.
    private func runnableRules() -> [Rule] {
        store.rules.filter { $0.isEnabled && $0.isRunnable }
    }

    private func watchedFolders() -> [URL] {
        let folders = runnableRules()
            .compactMap { folder(for: $0) }
        // Deduplicated: several rules on one folder must not mean several watchers on it.
        return Array(Set(folders.map(\.standardizedFileURL)))
    }

    private func folder(for rule: Rule) -> URL? {
        guard let bookmark = rule.folderBookmark else { return nil }
        return ActionRunner().resolveFolder(bookmark)
    }
}
