import Combine
import Foundation
import os

/// Decides whether to tell the user about a new version, from what the launchd job left on disk.
///
/// `state` is a plain `private(set) var` rather than `@Published`, and `refresh()` announces only
/// when the answer actually changes. The file is re-read on every menu bar panel open and every
/// window open — a `@Published` republishing an identical `.upToDate` on each of those is exactly
/// the shape of the write-back loop documented in `AppState`, which pinned a core at 100%.
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        /// Never checked, unreadable, or a tag we can't order. The UI says nothing in this state.
        case unknown
        case upToDate
        case available(LatestRelease)
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "UpdateCheck")
    private let store: UpdateFeedStore
    private let currentVersion: AppVersion?
    private let defaults: UserDefaults

    private(set) var state: State = .unknown
    private(set) var lastChecked: Date?
    private(set) var lastFailure: Date?

    /// A record older than this means the job is not running — most likely the user switched the
    /// background item off in System Settings. Saying "up to date" off a two-week-old answer
    /// would be a lie, so the UI says when it last managed to look instead.
    static let stalenessThreshold: TimeInterval = 60 * 60 * 24 * 3

    init(
        store: UpdateFeedStore = UpdateFeedStore(),
        currentVersion: AppVersion? = AppVersion.current(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.currentVersion = currentVersion
        self.defaults = defaults
        refresh()
    }

    var isStale: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) > Self.stalenessThreshold
    }

    /// The version the user asked not to be told about again.
    var skippedVersion: AppVersion? {
        defaults.string(forKey: Self.skippedVersionKey).flatMap(AppVersion.init)
    }

    /// Re-read and recompute. Cheap by design — one `stat` and a small decode — because it runs
    /// on four separate triggers and redundant calls have to be genuinely inert.
    func refresh() {
        let snapshot = store.read()
        let newState = Self.decide(
            current: currentVersion,
            latest: snapshot?.release,
            skipped: skippedVersion
        )
        let newChecked = snapshot?.checkedAt
        let newFailure = store.lastFailureAt

        guard newState != state || newChecked != lastChecked || newFailure != lastFailure else { return }
        objectWillChange.send()
        state = newState
        lastChecked = newChecked
        lastFailure = newFailure
    }

    /// Stop mentioning this version. A later one still gets through.
    func skip(_ release: LatestRelease) {
        guard let version = release.version else { return }
        objectWillChange.send()
        defaults.set(version.description, forKey: Self.skippedVersionKey)
        state = Self.decide(current: currentVersion, latest: release, skipped: version)
    }

    private static let skippedVersionKey = "updates.skippedVersion"

    /// The whole decision, as a pure function of three values.
    ///
    /// The `latest <= current` case is not a formality: every build between releases, and every
    /// build a developer runs, is ahead of the latest published version. That has to read as
    /// "nothing to do" and never as an update — an app that offers to downgrade you is worse than
    /// one that says nothing.
    static func decide(current: AppVersion?, latest: LatestRelease?, skipped: AppVersion?) -> State {
        // No answer, no version of our own, or a tag we can't order: say nothing rather than
        // guess. Silence is the correct failure here.
        guard let current, let latest, let latestVersion = latest.version else { return .unknown }
        guard latestVersion > current else { return .upToDate }
        if let skipped, latestVersion <= skipped { return .upToDate }
        return .available(latest)
    }
}
