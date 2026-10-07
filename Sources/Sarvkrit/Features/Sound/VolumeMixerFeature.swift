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
    let summary = "A separate volume and output for each app"
    let details = """
        Give each app its own volume. Turn a noisy one down without touching everything else, and \
        the setting sticks — an app you set to 40% is still at 40% next week.

        You can also send an app to its own speakers or headphones — music on the speakers, a call \
        in your AirPods. If that device goes away the app plays on your usual output, and goes back \
        when the device returns.

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
    /// The devices an app can be sent to.
    @Published private(set) var outputDevices: [AudioDevice] = []

    private var levels: MixerLevels
    private var routes: MixerRoutes
    private var defaultOutputUID: String?
    private let deviceMonitor = AudioDeviceMonitor()
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
        routes = MixerRoutes(defaults: defaults)
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

    /// Puts an app back to full volume on the system output.
    @MainActor
    func reset(_ bundleID: String) {
        objectWillChange.send()
        levels.reset(bundleID)
        routes.reset(bundleID)
        taps[bundleID]?.setLevel(1)
        reconcileTaps()
    }

    @MainActor
    func resetAll() {
        objectWillChange.send()
        levels.resetAll()
        routes.resetAll()
        teardownTaps()
    }

    /// Every app the user has set a level or an output for, so nothing is quietly turned down or
    /// sent somewhere they can't find it.
    var customisedBundleIDs: [String] {
        Set(levels.levels.keys).union(routes.routes.keys).sorted()
    }

    // MARK: - Outputs

    /// Nil when the app follows the system output.
    func route(for bundleID: String) -> MixerRoutes.Route? { routes.route(for: bundleID) }

    /// Whether the app's chosen device is connected right now. When it isn't, the app is playing on
    /// the system output and the UI should say so.
    func isRouteAvailable(for bundleID: String) -> Bool {
        guard let uid = routes.route(for: bundleID)?.uid else { return true }
        return outputDevices.contains { $0.uid == uid }
    }

    /// Nil sends the app back to the system output.
    @MainActor
    func setOutput(_ device: AudioDevice?, for bundleID: String) {
        let route = device.map { MixerRoutes.Route(uid: $0.uid, name: $0.name) }
        guard route != routes.route(for: bundleID) else { return }
        objectWillChange.send()
        routes.setRoute(route, for: bundleID)
        reconcileTaps()
    }

    // MARK: - Lifecycle

    func activate() {
        // Polling rather than a property listener: `kAudioProcessPropertyIsRunningOutput` changes
        // per app, and subscribing per process means adding and removing listeners as apps come and
        // go — more moving parts than a two-second poll for a list this short.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        // Devices, unlike processes, have a listener — and a re-route should happen when the
        // AirPods connect, not up to two seconds later.
        deviceMonitor.onChange = { [weak self] _ in self?.refresh() }
        deviceMonitor.start()
        refresh()
    }

    func deactivate() {
        // `Feature.deactivate()` isn't main-isolated, but `AppState.sync()` only ever calls it from
        // main — the same assumption the other features here make.
        MainActor.assumeIsolated {
            pollTimer?.invalidate()
            pollTimer = nil
            deviceMonitor.stop()
            teardownTaps()
            processes = []
            permissionLooksDenied = false
        }
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(VolumeMixerDetailView(feature: self))
    }

    /// Shares the Sound panel with the output switcher — see `OutputSwitcherFeature.trayPanels()`.
    @MainActor
    func trayPanels() -> [TrayPanel] {
        [TrayPanel(id: "sound", title: "Sound", symbolName: "slider.horizontal.3") {
            VolumeMixerTrayView(feature: self)
        }]
    }

    // MARK: - Keeping up with what's playing

    func refresh() {
        Self.workQueue.async { [weak self] in
            let found = AudioProcesses.current().filter(\.isPlaying)
            // Read here, off main, with the processes: `AudioSystem` blocks on coreaudiod.
            let devices = AudioSystem.devices()
            let defaultID = AudioSystem.defaultDevice(.output)
            let defaultUID = devices.first { $0.id == defaultID }?.uid
            let outputs = AudioDeviceList.selectable(from: devices, kind: .output)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.processes.map(\.id) != found.map(\.id) { self.processes = found }
                if self.outputDevices != outputs { self.outputDevices = outputs }
                self.defaultOutputUID = defaultUID
                self.reconcileTaps()
                self.checkForSilence()
            }
        }
    }

    /// A tap exists only for an app that is playing and either turned down or sent to another
    /// device — see `MixerPlan`. Tapping an app that would sound the same untapped would route its
    /// audio through us for no reason at all.
    ///
    /// A tap is bound to one output for its life, so a tap on the wrong device — the app was
    /// re-routed, its device left, or the system output changed under it — is torn down and made
    /// again. That costs a short gap in the audio, which is why it only happens on a real change.
    @MainActor
    private func reconcileTaps() {
        let wanted = MixerPlan.desiredTaps(
            playing: processes.map(\.bundleID),
            levels: levels,
            routes: routes,
            outputs: outputDevices,
            defaultOutputUID: defaultOutputUID
        )

        for (bundleID, tap) in taps where wanted[bundleID] != tap.outputUID {
            tap.destroy()
            taps.removeValue(forKey: bundleID)
        }

        for process in processes where taps[process.bundleID] == nil {
            guard let outputUID = wanted[process.bundleID],
                  let tap = AudioProcessTap(
                      processObjectID: process.id,
                      bundleID: process.bundleID,
                      level: levels.level(for: process.bundleID),
                      outputUID: outputUID
                  )
            else { continue }
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
