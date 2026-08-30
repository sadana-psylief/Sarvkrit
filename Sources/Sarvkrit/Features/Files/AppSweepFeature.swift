import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// Offers to clean up an app's leftovers after you delete it.
///
/// Two things make this safe rather than reckless, and both are easy to get wrong:
///
/// 1. **An inventory.** A deleted bundle can't be read, so its identifier must have been recorded
///    while it was still installed.
/// 2. **A settle window.** App updates are a delete followed by a replace. Sweeping immediately
///    would destroy the preferences of an app that is merely updating.
final class AppSweepFeature: Feature, ObservableObject {
    let id = "app-sweep"
    let category = FeatureCategory.files
    let title = "App Sweep"
    let summary = "Clean up after deleted apps"
    let details = """
        When you delete an application, Sarvkrit looks for the support files, caches and preferences \
        it leaves behind, and offers to remove them.

        It never sweeps on its own: you always see the list, with sizes, and choose what goes. \
        Everything selected is moved to the Trash, not deleted, so a mistake is recoverable. Apps \
        that are merely updating are ignored.
        """
    let symbolName = "sparkles"
    let requirements: Set<Requirement> = []

    /// A pending offer, surfaced in the detail pane.
    struct Finding: Identifiable, Equatable {
        var app: AppLeftovers.InstalledApp
        var candidates: [AppLeftovers.Candidate]
        var id: String { app.bundleID }
        var totalSize: Int64 { candidates.reduce(0) { $0 + $1.size } }
    }

    @Published private(set) var findings: [Finding] = []

    /// Published so "Apps tracked" updates — including right after pressing Rescan, which
    /// previously appeared to do nothing at all.
    @Published private(set) var inventory: [AppLeftovers.InstalledApp] = []

    /// How long to wait before believing a disappearance is a deletion rather than an update.
    private let settleWindow: TimeInterval
    private let applicationsURL = URL(fileURLWithPath: "/Applications")
    private let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "AppSweep")
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private lazy var watcher = FolderWatcher(coalesceInterval: 2.0) { [weak self] _ in
        self?.scheduleCheck()
    }
    private var pendingCheck: DispatchWorkItem?

    private static let inventoryKey = "appSweep.inventory"

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        settleWindow: TimeInterval = 60
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.settleWindow = settleWindow
        self.inventory = loadInventory()
    }

    func activate() {
        // Compare, don't overwrite. `refreshInventory()` here meant an app deleted while Sarvkrit
        // wasn't running was silently forgotten on the next launch — and since AppState reactivates
        // every feature whenever *any* toggle changes, an unrelated switch wiped pending findings
        // too. checkForRemovals() diffs first and only then updates the inventory.
        checkForRemovals()
        watcher.start(watching: [applicationsURL])
    }

    func deactivate() {
        pendingCheck?.cancel()
        pendingCheck = nil
        watcher.stop()
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(AppSweepDetailView(feature: self))
    }

    // MARK: - Inventory

    private func loadInventory() -> [AppLeftovers.InstalledApp] {
        guard let data = defaults.data(forKey: Self.inventoryKey),
              let decoded = try? JSONDecoder().decode([AppLeftovers.InstalledApp].self, from: data)
        else { return [] }
        return decoded
    }

    private func storeInventory(_ apps: [AppLeftovers.InstalledApp]) {
        inventory = apps
        guard let data = try? JSONEncoder().encode(apps) else { return }
        defaults.set(data, forKey: Self.inventoryKey)
    }

    func scanInstalledApps() -> [AppLeftovers.InstalledApp] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: applicationsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            guard url.pathExtension == "app",
                  let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier
            else { return nil }
            return AppLeftovers.InstalledApp(
                bundleID: bundleID,
                name: url.deletingPathExtension().lastPathComponent,
                path: url.path
            )
        }
    }

    /// Replaces the inventory outright. Only for an explicit Rescan — everything else compares.
    func refreshInventory() {
        storeInventory(scanInstalledApps())
    }

    // MARK: - Detecting removals

    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkForRemovals() }
        pendingCheck = work
        // The settle window: an update replaces the bundle within seconds, and waiting is the
        // difference between cleaning up after an uninstall and vandalising an upgrade.
        DispatchQueue.main.asyncAfter(deadline: .now() + settleWindow, execute: work)
    }

    func checkForRemovals() {
        let remembered = loadInventory()
        inventory = remembered
        // Genuinely nothing remembered — a first run. Seed it; there's nothing to compare against.
        guard !remembered.isEmpty else {
            refreshInventory()
            return
        }

        let present = scanInstalledApps()
        let presentPaths = Set(present.map(\.path))
        let registered = Set(remembered.compactMap { app -> String? in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
                ? app.bundleID : nil
        })

        let removed = AppLeftovers.removedApps(
            inventory: remembered,
            stillPresentPaths: presentPaths,
            stillRegisteredBundleIDs: registered
        )

        let newFindings = removed.compactMap { app -> Finding? in
            let candidates = AppLeftovers.findCandidates(
                for: app.bundleID, libraryURL: libraryURL, fileManager: fileManager
            )
            guard !candidates.isEmpty else { return nil }
            log.info("\(app.name, privacy: .public) was removed; \(candidates.count) leftover(s) found")
            return Finding(app: app, candidates: candidates)
        }

        DispatchQueue.main.async {
            for finding in newFindings where !self.findings.contains(where: { $0.id == finding.id }) {
                self.findings.append(finding)
            }
            // Only now is the inventory updated, so a removal isn't forgotten before it's offered.
            self.storeInventory(present)
        }
    }

    // MARK: - Acting

    /// Moves the chosen leftovers to the Trash. Never deletes: a wrong guess has to be recoverable.
    func sweep(_ finding: Finding, selected: Set<String>) {
        for candidate in finding.candidates where selected.contains(candidate.id) {
            do {
                try fileManager.trashItem(at: candidate.url, resultingItemURL: nil)
                log.info("trashed leftover \(candidate.url.lastPathComponent, privacy: .public)")
            } catch {
                log.error("could not trash \(candidate.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        dismiss(finding)
    }

    func dismiss(_ finding: Finding) {
        findings.removeAll { $0.id == finding.id }
    }
}
