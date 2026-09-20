import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// Watches the fans, and — once the privileged half of this feature lands — sets their speed.
///
/// Today this is the monitor half only: it reads `FNum` and each fan's speed, range and mode, all
/// of it unprivileged. No password, no prompt, no TCC grant, and nothing leaves the Mac.
///
/// Three things here are load-bearing:
///
/// **Nothing samples until it is switched on.** `FeatureRegistry.makeAll()` constructs every
/// feature at launch regardless of its toggle, so `init` opens no user client at all — the sampler
/// is built in `activate()` and dropped in `deactivate()`.
///
/// **Sampling never touches the main thread.** The event tap's run loop lives there, and a
/// blocking IOKit call on it is felt as input latency in whatever app the user is typing in. Same
/// rule as `SystemMonitorFeature` and `KeepAwakeFeature.reconcile()`.
///
/// **A fanless Mac is polled once and then left alone.** Every Apple Silicon MacBook Air answers
/// `FNum = 0`, and that answer will not change before the next launch. A timer running forever to
/// re-read it would be pure cost for a panel that can only say the same sentence.
///
/// It reads the fans itself rather than adding a `MetricKind` to `SystemMonitor`, for two reasons
/// worth writing down. `systemMonitor.enabledMetrics` only falls back to "everything" when the key
/// is *absent*, so a new metric would arrive switched off for anyone who had ever customised that
/// list. And the SMC is a single serialised coprocessor — two features polling the same keys on
/// two queues is the kind of thing this codebase already refuses at the hardware layer.
final class FanControlFeature: Feature, ObservableObject {
    let id = "fan-control"
    let category = FeatureCategory.system
    let title = "Fan Control"
    let summary = "Watch the fans and set their speed"
    let details = """
        Shows what each fan is doing — its speed now, and the range it can run in.

        Fan speeds come from the System Management Controller, the same coprocessor macOS uses to \
        decide how fast the fans should run. Reading it needs no password and no permission, and \
        nothing leaves your Mac.

        A stopped fan reads 0 rpm rather than a dash. On Apple Silicon that is the normal state \
        when the Mac is cool — the fans genuinely stop, rather than idling slowly.

        Macs with no fans, which is every MacBook Air, say so.
        """
    let symbolName = "fan"
    /// The protocol default is `[.accessibility]`. This feature reads a coprocessor; gating it
    /// behind a grant it has no use for would be asking for something under false pretences.
    let requirements: Set<Requirement> = []

    private(set) var isRunning = false
    private(set) var hardware: FanHardware = .unreadable

    /// Whether a timer is actually running. False on a fanless Mac even while the feature is on,
    /// which is the distinction the panel and the tests both care about.
    var isPolling: Bool { timer != nil }

    private let defaults: UserDefaults
    private let makeSampler: () -> FanSampler
    private var sampler: FanSampler?
    private var timer: Timer?
    /// Invalidates a sample already in flight when the feature is switched off, so a reading
    /// computed for a run that has ended can never land in the panel.
    private var generation = 0

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "FanControl")
    private static let workQueue = DispatchQueue(label: "\(AppIdentity.bundleID).fan-control")

    /// Two seconds, matching `SystemMonitorFeature`'s default and `VolumeMixerFeature`. A fan
    /// does not change fast enough to reward anything quicker.
    private static let interval: TimeInterval = 2

    init(defaults: UserDefaults = .standard,
         makeSampler: @escaping () -> FanSampler = { FanSampler() }) {
        self.defaults = defaults
        self.makeSampler = makeSampler
    }

    // MARK: - Lifecycle

    func activate() {
        objectWillChange.send()
        generation += 1
        isRunning = true
        sampler = makeSampler()
        poll()
    }

    func deactivate() {
        // Not main-isolated: `AppState.deinit` calls this on whatever thread is tearing down.
        MainActor.assumeIsolated {
            objectWillChange.send()
            generation += 1
            isRunning = false
            timer?.invalidate()
            timer = nil
            sampler = nil
            // Off means off. A panel still showing the last speed it saw would be claiming to
            // watch something it has stopped watching.
            hardware = .unreadable
        }
    }

    // MARK: - Sampling

    private func poll() {
        let token = generation
        guard let sampler else { return }

        Self.workQueue.async { [weak self] in
            let reading = sampler.read()
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.isRunning else { return }
                self.apply(reading)
            }
        }
    }

    private func apply(_ reading: FanHardware) {
        if reading != hardware {
            objectWillChange.send()
            hardware = reading
        }

        switch reading {
        case .fanless:
            // Settled, and it will not change before the next launch.
            timer?.invalidate()
            timer = nil
            Self.log.notice("this Mac reports no fans")
        case .unreadable, .fans:
            startTimerIfNeeded()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, isRunning else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // `.common`, so the readings do not freeze while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - UI

    @MainActor
    func trayPanels() -> [TrayPanel] {
        [
            TrayPanel(id: "fans", title: "Fans", symbolName: "fan") {
                FanPanelView(feature: self)
            }
        ]
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(FanControlDetailView(feature: self))
    }
}
