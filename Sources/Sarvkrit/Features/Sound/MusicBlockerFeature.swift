import AppKit
import Foundation
import SwiftUI
import os

/// Stops Apple Music opening itself when headphones connect.
///
/// Needs no permission: watching app launches and quitting an app are both ordinary `NSWorkspace`
/// operations.
///
/// The judgement of *which* launches to stop lives in `MusicLaunchDecision` — see there for why a
/// device change is the tell. This class is the glue that feeds it.
final class MusicBlockerFeature: Feature, ObservableObject {
    let id = "music-blocker"
    let category = FeatureCategory.sound
    let title = "Music Blocker"
    let summary = "Stop Music opening when headphones connect"
    let details = """
        Connecting headphones or a Bluetooth speaker often makes Apple Music open itself, whether \
        you wanted it or not. This closes it again when that happens.

        Opening Music yourself still works. Sarvkrit only steps in when it appears within a few \
        seconds of an audio device connecting — which is what a self-launch looks like, and what \
        deliberately opening it doesn't.

        You'll see a brief message when it does, so an app closing is never a mystery.

        No permissions needed.
        """
    let symbolName = "music.note"
    let requirements: Set<Requirement> = []

    /// How many times it has stepped in, so the pane can show the feature is doing something rather
    /// than merely being switched on.
    @Published private(set) var blockedCount: Int

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "MusicBlocker")
    private let monitor = AudioDeviceMonitor()
    private let defaults: UserDefaults
    private let workspace: NSWorkspace

    /// When an audio device last appeared or vanished. The whole decision rests on this.
    private var lastDeviceChange: Date?
    private var launchObserver: NSObjectProtocol?

    private static let countKey = "sound.musicBlockedCount"

    init(defaults: UserDefaults = .standard, workspace: NSWorkspace = .shared) {
        self.defaults = defaults
        self.workspace = workspace
        self.blockedCount = defaults.integer(forKey: Self.countKey)
    }

    // MARK: - Lifecycle

    func activate() {
        // Seeded deliberately empty: a device change from before the feature was switched on must
        // not make the next launch look triggered.
        lastDeviceChange = nil

        monitor.onChange = { [weak self] _ in
            // Arrives on the monitor's queue.
            DispatchQueue.main.async { self?.lastDeviceChange = Date() }
        }
        monitor.start()

        launchObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            // The notification is delivered on the main queue, which is where `consider` needs to
            // be — it touches published state and raises a toast.
            MainActor.assumeIsolated { self?.consider(app) }
        }
    }

    func deactivate() {
        monitor.stop()
        monitor.onChange = nil
        if let launchObserver {
            workspace.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        lastDeviceChange = nil
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(MusicBlockerDetailView(feature: self))
    }

    func resetCount() {
        guard blockedCount != 0 else { return }
        blockedCount = 0
        defaults.set(0, forKey: Self.countKey)
    }

    // MARK: - Deciding

    @MainActor
    private func consider(_ app: NSRunningApplication?) {
        guard let app, MusicLaunchDecision.isMusic(bundleID: app.bundleIdentifier) else { return }
        guard MusicLaunchDecision.verdict(
            launchedAt: Date(), lastDeviceChange: lastDeviceChange
        ) == .block else {
            log.info("Music opened, and not by a device change — left alone")
            return
        }

        // The device change has been spent. Without this, a second launch moments later — Music
        // relaunching itself, which it sometimes does — would also be blocked, and the user could
        // not open it at all until another device event came along.
        lastDeviceChange = nil

        app.terminate()
        blockedCount += 1
        defaults.set(blockedCount, forKey: Self.countKey)
        log.notice("closed Music, which opened itself after an audio device changed")

        // An app being quietly killed is indistinguishable from it crashing.
        ToastPresenter.shared.show("Music was opening — closed it", symbolName: "music.note")
    }
}
