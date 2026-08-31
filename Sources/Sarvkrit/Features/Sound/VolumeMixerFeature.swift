import AppKit
import CoreAudio
import Foundation
import SwiftUI

/// A volume for each app that's making sound.
///
/// Works by tapping each app's audio and re-rendering it attenuated — see `AudioProcessTap` for
/// how, and for why this is the only way to do it without shipping an audio driver.
///
/// **This is the one feature here that needs a permission**, and it is an unusual one: system audio
/// recording has no API to request it and none to ask whether it was granted, and denial is silent.
/// So the feature can't be gated up front like the event-tap features; it starts, and then notices
/// it heard nothing. `permissionLooksDenied` is that noticing.
final class VolumeMixerFeature: Feature, ObservableObject {
    let id = "volume-mixer"
    let category = FeatureCategory.sound
    let title = "Volume Mixer"
    let summary = "A separate volume for each app"
    let details = """
        Give each app its own volume. Turn a noisy one down without touching everything else, and \
        the setting sticks — an app you set to 40% is still at 40% next week.

        Apps appear here while they're playing, because that's when a mixer is useful.

        macOS has no built-in way to do this. Sarvkrit routes each app's audio through itself to \
        change the level, which macOS treats as recording that audio — so the first time you use it \
        you'll be asked to allow it. Nothing is written down or sent anywhere; the audio is scaled \
        and passed straight on.
        """
    let symbolName = "slider.vertical.3"
    let requirements: Set<Requirement> = [.audioCapture]

    /// Apps currently making sound.
    @Published private(set) var processes: [AudioProcess] = []
    /// Set once we've been rendering for a while and heard nothing but silence — which is what a
    /// refused permission looks like, since every call still reports success.
    @Published private(set) var permissionLooksDenied = false

    private var levels: MixerLevels
    private var taps: [String: AudioProcessTap] = [:]
    private var pollTimer: Timer?

    /// How long of nothing-but-silence before we say the permission looks refused.
    ///
    /// Generous on purpose: an app can legitimately be "running output" while genuinely silent —
    /// paused, or between tracks — and accusing the user of denying a permission they granted would
    /// be worse than saying nothing.
    private static let silentRendersBeforeSuspecting = 400

    init(defaults: UserDefaults = .standard) {
        levels = MixerLevels(defaults: defaults)
    }

    // MARK: - Levels

    func level(for bundleID: String) -> Float { levels.level(for: bundleID) }

    @MainActor
    func setLevel(_ level: Float, for bundleID: String) {
        guard level != levels.level(for: bundleID) else { return }
        objectWillChange.send()
        levels.setLevel(level, for: bundleID)
        // Live: the tap reads this on its next render.
        taps[bundleID]?.setLevel(level)
        reconcileTaps()
    }

    @MainActor
    func resetLevel(for bundleID: String) {
        objectWillChange.send()
        levels.reset(bundleID)
        taps[bundleID]?.setLevel(1)
        reconcileTaps()
    }

    @MainActor
    func resetAllLevels() {
        objectWillChange.send()
        levels.resetAll()
        teardownTaps()
    }

    /// Every app the user has set a level for, so nothing is quietly turned down somewhere they
    /// can't find it.
    var customisedBundleIDs: [String] { levels.levels.keys.sorted() }

    // MARK: - Lifecycle

    func activate() {
        // Polling rather than a property listener: `kAudioProcessPropertyIsRunningOutput` changes
        // per app, and subscribing per process means adding and removing listeners as apps come and
        // go — more moving parts than a two-second poll for a list this short.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    func deactivate() {
        // `Feature.deactivate()` isn't main-isolated, but `AppState.sync()` only ever calls it from
        // main — the same assumption the other features here make.
        MainActor.assumeIsolated {
            pollTimer?.invalidate()
            pollTimer = nil
            teardownTaps()
            processes = []
            permissionLooksDenied = false
        }
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(VolumeMixerDetailView(feature: self))
    }

    @MainActor
    func makeTrayView() -> AnyView? {
        AnyView(VolumeMixerTrayView(feature: self))
    }

    // MARK: - Keeping up with what's playing

    func refresh() {
        Self.workQueue.async { [weak self] in
            let found = AudioProcesses.current().filter(\.isPlaying)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.processes.map(\.id) != found.map(\.id) { self.processes = found }
                self.reconcileTaps()
                self.checkForSilence()
            }
        }
    }

    /// A tap exists only for an app that is both playing and turned down. Tapping an app at full
    /// volume would route its audio through us for no reason at all.
    @MainActor
    private func reconcileTaps() {
        let wanted = Set(
            processes
                .filter { levels.hasCustomLevel(for: $0.bundleID) }
                .map(\.bundleID)
        )

        for (bundleID, tap) in taps where !wanted.contains(bundleID) {
            tap.destroy()
            taps.removeValue(forKey: bundleID)
        }

        for process in processes where wanted.contains(process.bundleID) && taps[process.bundleID] == nil {
            guard let tap = AudioProcessTap(
                processObjectID: process.id,
                bundleID: process.bundleID,
                level: levels.level(for: process.bundleID)
            ) else { continue }
            taps[process.bundleID] = tap
        }
    }

    @MainActor
    private func teardownTaps() {
        taps.values.forEach { $0.destroy() }
        taps.removeAll()
    }

    /// Denial is silent, so this is the only way to notice it.
    @MainActor
    private func checkForSilence() {
        guard !taps.isEmpty else {
            if permissionLooksDenied { permissionLooksDenied = false }
            return
        }
        let allSilent = taps.values.allSatisfy {
            $0.silentRenderCount > Self.silentRendersBeforeSuspecting
        }
        if permissionLooksDenied != allSilent { permissionLooksDenied = allSilent }
    }

    private static let workQueue = DispatchQueue(label: "\(AppIdentity.bundleID).mixer")
}
