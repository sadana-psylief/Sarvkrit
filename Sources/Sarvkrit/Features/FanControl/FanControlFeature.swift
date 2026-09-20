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
    private let makeSink: (String) -> FanCommandSink
    private let readTemperature: () -> Double?
    private let runPrivileged: (String) -> Bool
    private var sampler: FanSampler?
    private var sink: FanCommandSink?
    private let thermal = ThermalSampler()

    private let throttle = FanWriteThrottle()
    private var lastCommand: FanCommand?
    private var lastCommandAt: Date?
    private var isEngaged = false

    /// The helper went away while we were driving. A stated condition, never a cue to re-prompt.
    private(set) var controlWasLost = false
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
         makeSampler: @escaping () -> FanSampler = { FanSampler() },
         makeSink: ((String) -> FanCommandSink)? = nil,
         readTemperature: (() -> Double?)? = nil,
         runPrivileged: @escaping (String) -> Bool = SleepDisableFlag.runPrivileged) {
        self.defaults = defaults
        self.makeSampler = makeSampler
        self.runPrivileged = runPrivileged
        self.makeSink = makeSink ?? { path in
            FanHelperSession(socketPath: path, runPrivileged: runPrivileged)
        }
        // Its own ThermalSampler rather than System Monitor's. `Feature` has no way to depend on
        // a sibling, and putting a second toggle in the failure path of a thermal safety loop
        // would be a poor trade for one cached HID walk.
        self.readTemperature = readTemperature ?? { [thermal] in thermal.read()?.cpu }
    }

    // MARK: - What the user asked for

    private static let modeKey = "fanControl.mode"
    private static let weForcedKey = "fanControl.weForcedIt"

    /// Persisted, but **never acted on at launch**: a Mac that boots holding its fans because of
    /// a setting from last week, with no prompt and no explanation, is not something to build.
    /// Restoring a mode is the user picking it again.
    var mode: FanMode {
        get {
            guard let data = defaults.data(forKey: Self.modeKey),
                  let stored = try? JSONDecoder().decode(FanMode.self, from: data)
            else { return .monitor }
            return stored
        }
        set {
            guard newValue != mode else { return }
            objectWillChange.send()
            store(newValue)
            apply(newValue)
        }
    }

    private func store(_ newMode: FanMode) {
        defaults.set(try? JSONEncoder().encode(newMode), forKey: Self.modeKey)
    }

    private var weForcedIt: Bool {
        get { defaults.bool(forKey: Self.weForcedKey) }
        set { defaults.set(newValue, forKey: Self.weForcedKey) }
    }

    // MARK: - Lifecycle

    func activate() {
        objectWillChange.send()
        generation += 1
        isRunning = true
        controlWasLost = false
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
            // Costs no password: the helper is already root and already connected. A prompt to
            // *stop* doing something would be indefensible.
            sink?.stop()
            sink = nil
            weForcedIt = false
            isEngaged = false
            lastCommand = nil
            lastCommandAt = nil
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

    // MARK: - Driving

    /// One step of the control loop. Separate from the timer so a test can advance it by hand.
    func tick() {
        guard isRunning else { return }
        let command = FanPolicy.command(
            mode: mode, celsius: readTemperature(), isEngaged: isEngaged)

        switch command {
        case .hold: isEngaged = true
        case .release: isEngaged = false
        }

        guard throttle.shouldWrite(command, lastWritten: lastCommand,
                                   lastWriteAt: lastCommandAt, now: Date())
        else { return }

        deliver(command)
    }

    private func deliver(_ command: FanCommand) {
        switch command {
        case let .hold(percent):
            guard let sink, sink.isConnected else { return }
            sink.send(.set(percent: Int(percent.rounded())))
            weForcedIt = true
        case .release:
            sink?.send(.auto)
            weForcedIt = false
        }
        lastCommand = command
        lastCommandAt = Date()
    }

    /// Starts or stops the helper to match the mode the user just picked.
    private func apply(_ newMode: FanMode) {
        guard isRunning else { return }

        guard newMode != .monitor else {
            sink?.stop()
            sink = nil
            weForcedIt = false
            isEngaged = false
            lastCommand = nil
            lastCommandAt = nil
            return
        }

        if sink == nil || sink?.isConnected == false {
            let session = makeSink(FanHelperSession.defaultSocketPath())
            session.onLost = { [weak self] in self?.helperWentAway() }
            guard session.start() else {
                // Cancelled, or the helper never appeared. Nothing half-on: fall back to
                // watching, writing straight to defaults so the setter does not recurse.
                objectWillChange.send()
                store(.monitor)
                sink = nil
                return
            }
            sink = session
        }

        controlWasLost = false
        lastCommand = nil
        lastCommandAt = nil
        tick()
    }

    /// The helper died. Say so and stop; **never re-prompt.** A crash loop that reopens a
    /// password dialog every few seconds is indistinguishable from malware.
    private func helperWentAway() {
        objectWillChange.send()
        controlWasLost = true
        weForcedIt = false
        isEngaged = false
        sink = nil
        store(.monitor)
        Self.log.error("the fan helper went away; the fans are back on macOS")
    }

    private func startTimerIfNeeded() {
        guard timer == nil, isRunning else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
            self?.tick()
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
