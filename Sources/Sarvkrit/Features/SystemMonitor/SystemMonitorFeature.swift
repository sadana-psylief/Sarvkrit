import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// How often the monitor samples.
///
/// Two seconds by default, matching the only comparable poller in the app (`VolumeMixerFeature`).
/// This project argues against fast timers repeatedly and in writing — `MenuBarLabel` re-reads
/// twice a minute because "a per-second timer in the menu bar is exactly the idle cost this app has
/// spent effort removing" — so the fast option exists but is not what anyone gets by default.
enum MonitorInterval: String, CaseIterable, Identifiable, Codable {
    case oneSecond
    case twoSeconds
    case fiveSeconds

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .oneSecond: return 1
        case .twoSeconds: return 2
        case .fiveSeconds: return 5
        }
    }

    var title: String {
        switch self {
        case .oneSecond: return "Every second"
        case .twoSeconds: return "Every 2 seconds"
        case .fiveSeconds: return "Every 5 seconds"
        }
    }
}

/// The current readings and their sparkline windows, as one value.
///
/// Deliberately one struct rather than two properties: the pane and the menu bar both want them
/// together, and publishing them separately would send two notifications per tick for what is
/// logically one event.
struct MonitorReading: Equatable {
    var snapshot = SystemSnapshot()
    var history: [MetricKind: MetricHistory] = [:]
}

/// Watches CPU, GPU, power, battery, memory, disk and network.
///
/// The feature owns the timer, the persisted settings and the rate baselines; everything about what
/// a reading *means* lives in the pure types beside it. Three things here are load-bearing and
/// none is obvious:
///
/// **Nothing samples until it is switched on.** `FeatureRegistry.makeAll()` constructs every
/// feature at launch regardless of its toggle, so `init` must start nothing at all, and
/// `deactivate()` — which `AppState.sync()` calls synchronously inside the toggle write — is the
/// whole of the "off means off" promise.
///
/// **Sampling never touches the main thread.** The event tap's run loop lives there, and a blocking
/// Mach or IOKit call on it is felt as input latency in whatever app the user is typing in. The
/// same rule `AudioSystem` and `KeepAwakeFeature.reconcile()` already follow.
///
/// **A sample in flight must not outlive being switched off.** Between the queue hop and the
/// publish, the user can toggle the feature off; the reset would then be undone by a reading that
/// arrived late. `generation` is what stops that.
final class SystemMonitorFeature: Feature, ObservableObject {
    let id = "system-monitor"
    let category = FeatureCategory.system
    let title = "System Monitor"
    let summary = "Watch CPU, memory, disk and power"
    let details = """
        Shows what your Mac is actually doing: CPU and GPU load, memory and disk use, network \
        throughput, and where its power is coming from. Each of the seven readings can be switched \
        on or off on its own, and nothing is sampled for one you've turned off.

        A compact readout sits in the menu bar — you choose which numbers appear there — and \
        clicking it shows everything at once. Two minutes of history is kept in memory to draw the \
        graphs, and it is discarded the moment you switch the monitor off.
        """
    let symbolName = "gauge.with.dots.needle.67percent"
    /// No Accessibility: this reads counters, it doesn't touch input. Inheriting the protocol's
    /// default would gate the monitor behind a grant it has no use for.
    let requirements: Set<Requirement> = []

    /// Hand-rolled rather than `@Published`, like the rest of this app's observable state: it makes
    /// the notification count per user action exactly one, which is what `AppState`'s note on the
    /// same subject was written after discovering.
    private(set) var isRunning = false
    private(set) var reading = MonitorReading()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SystemMonitor")
    private let defaults: UserDefaults
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// Bumped by every `activate()` and `deactivate()`, and read only on the main thread. A sample
    /// dispatched before a toggle-off would otherwise land after it and repopulate the reading the
    /// toggle just cleared — leaving the pane showing live data for a feature that is off.
    private var generation = 0

    // Rate baselines. Written and read only from `workQueue`; see `takeSnapshot()`.
    private var previousCPU: CPUTicks?
    private var previousNetwork: NetworkCounters?
    private var previousDisk: DiskThroughput?
    private var previousSampledAt: Date?
    /// Running totals for the session, alongside the rate baselines and on the same queue.
    private var networkDownloaded = SessionTotals()
    private var networkUploaded = SessionTotals()
    /// Holds a cached HID client, so it is an instance rather than an enum of statics like the
    /// other samplers.
    private let thermal = ThermalSampler()
    /// SMART is a user-client round trip to the drive, and a figure that does not move within a
    /// session. Sampling it every two seconds alongside everything else would be pure cost.
    private var smart: SMARTReader.Reading?
    private var smartReadAt: Date?

    private static let metricsKey = "systemMonitor.enabledMetrics"
    private static let menuBarKey = "systemMonitor.menuBarMetrics"
    private static let intervalKey = "systemMonitor.interval"
    private static let liveDataKey = "systemMonitor.liveDataInMenuBar"

    /// Serial, and labelled from the bundle ID like every other worker in this app.
    private static let workQueue = DispatchQueue(label: "\(AppIdentity.bundleID).system-monitor")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Settings

    /// Everything, unless the user has said otherwise: switching on "System Monitor" means all of
    /// it, and opting out is the per-metric toggles' job.
    var enabledMetrics: Set<MetricKind> {
        get {
            guard let stored = defaults.array(forKey: Self.metricsKey) as? [String] else {
                return Set(MetricKind.allCases)
            }
            // compactMap, not map: a metric removed in a later release, or a downgrade, must not
            // take the pane down with it.
            return Set(stored.compactMap(MetricKind.init(rawValue:)))
        }
        set {
            guard newValue != enabledMetrics else { return }
            objectWillChange.send()
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.metricsKey)
            // A metric switched off loses its window too. Keeping it would make switching the
            // metric back on draw a jump from stale data rather than starting a fresh line.
            for kind in reading.history.keys where !newValue.contains(kind) {
                reading.history[kind] = nil
            }
        }
    }

    /// Which readings appear in the menu bar, in the order they appear. Empty means the icon alone.
    ///
    /// One by default. The readout shares the app's own icon rather than owning a status item, and
    /// "5m \u{00B7} CPU 16% \u{00B7} MEM 66%" — the Keep Awake countdown plus two metrics — is a lot of menu bar
    /// to claim beside an icon the user did not ask to grow.
    var menuBarMetrics: [MetricKind] {
        get {
            guard let stored = defaults.array(forKey: Self.menuBarKey) as? [String] else {
                return [.cpu]
            }
            return stored.compactMap(MetricKind.init(rawValue:))
        }
        set {
            guard newValue != menuBarMetrics else { return }
            objectWillChange.send()
            defaults.set(newValue.map(\.rawValue), forKey: Self.menuBarKey)
        }
    }

    /// Whether the readings appear beside the Sarvkrit icon.
    ///
    /// On by default: switching the monitor on at all is already the signal that someone wants to
    /// see it. Switching this off is purely about the menu bar — sampling continues and every
    /// reading stays available in the Sarvkrit menu.
    var showsLiveDataInMenuBar: Bool {
        get { defaults.object(forKey: Self.liveDataKey) as? Bool ?? true }
        set {
            guard newValue != showsLiveDataInMenuBar else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.liveDataKey)
        }
    }

    var interval: MonitorInterval {
        get {
            defaults.string(forKey: Self.intervalKey)
                .flatMap(MonitorInterval.init(rawValue:)) ?? .twoSeconds
        }
        set {
            guard newValue != interval else { return }
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.intervalKey)
            // A window holding both 1-second and 5-second samples misrepresents its own x-axis:
            // sixty samples would claim two minutes of history across a span covering five.
            reading.history.removeAll()
            if isRunning { restartTimer() }
        }
    }

    // MARK: - Lifecycle

    func activate() {
        objectWillChange.send()
        generation += 1
        isRunning = true
        discardBaselines()
        // Only here, and deliberately not in `discardBaselines()`. That also runs on wake, where
        // the rate baselines must go — a rate spanning a nap is fiction — but the session totals
        // must not: bytes that moved before the Mac slept really did move, and zeroing them on
        // every wake would make the figure mean nothing at all.
        resetSessionTotals()
        restartTimer()
        observeWake()
        poll()
    }

    func deactivate() {
        // `Feature.deactivate()` isn't main-isolated, but `AppState.sync()` only ever calls it from
        // main — the same assumption the other features here make. It also runs from
        // `AppState.deinit`, which is why this is asserted rather than dispatched.
        MainActor.assumeIsolated {
            objectWillChange.send()
            generation += 1
            isRunning = false
            timer?.invalidate()
            timer = nil
            if let wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
                self.wakeObserver = nil
            }
            // History is in-memory only, and off means off — a switched-off monitor must not keep
            // showing its last reading.
            reading = MonitorReading()
            discardBaselines()
        }
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(SystemMonitorDetailView(feature: self))
    }

    /// Every reading, as its own panel in the Sarvkrit menu.
    ///
    /// This is where the readings live. The monitor deliberately adds no status item of its own —
    /// Sarvkrit is one menu bar icon — so the dropdown is the place the full set is shown, and the
    /// menu bar text beside the icon is only ever a summary.
    ///
    /// Four panels, not one. Seven readings in a single card is a list you scan rather than an
    /// instrument you read, and a 420pt window holds one card comfortably and four badly.
    ///
    /// All four appear together whenever the monitor is on, including for metrics the user has
    /// switched off — those render dimmed with a dash. Which metrics are enabled is state inside
    /// this object, and SwiftUI does not observe through a nested `ObservableObject`, so a strip
    /// that added and removed tabs per metric would go stale the moment one was toggled in the
    /// settings window.
    @MainActor
    func trayPanels() -> [TrayPanel] {
        [
            TrayPanel(id: "system", title: "System", symbolName: "cpu") {
                SystemPanelView(feature: self)
            },
            TrayPanel(id: "network", title: "Network", symbolName: "globe") {
                NetworkPanelView(feature: self)
            },
            TrayPanel(id: "disks", title: "Disks", symbolName: "internaldrive") {
                DisksPanelView(feature: self)
            },
            TrayPanel(id: "power", title: "Power", symbolName: "bolt") {
                PowerPanelView(feature: self)
            },
        ]
    }

    // MARK: - Sampling

    /// Reads every enabled metric.
    ///
    /// **Call this on `workQueue`.** It mutates the rate baselines, and it blocks on Mach and IOKit
    /// calls that must never run on the thread hosting the event tap. Tests call it directly, which
    /// is safe only because they do so with no timer running.
    func takeSnapshot() -> SystemSnapshot {
        let metrics = enabledMetrics
        let now = Date()
        // Measured, never the nominal interval: a timer fires late, and using the setting instead
        // makes every rate quietly wrong by the drift.
        let elapsed = previousSampledAt.map { now.timeIntervalSince($0) }
        var snapshot = SystemSnapshot()

        // One pass over the sensors for both, the same way Battery and Power share one registry
        // pass: they are separate rows reading the same hardware.
        let temperatures = (metrics.contains(.cpu) || metrics.contains(.gpu))
            ? thermal.read() : nil

        if metrics.contains(.cpu), let ticks = CPUSampler.readTicks() {
            snapshot.cpu = CPUSample(
                celsius: temperatures?.cpu,
                usage: previousCPU.flatMap { CPULoad.usage(previous: $0, current: ticks) },
                coreCount: CPUSampler.coreCount
            )
            previousCPU = ticks
        }

        if metrics.contains(.gpu), let usage = GPUSampler.readUtilization() {
            snapshot.gpu = GPUSample(usage: usage, celsius: temperatures?.gpu)
        }

        if metrics.contains(.memory) {
            snapshot.memory = MemorySampler.read()
        }

        if metrics.contains(.disk) { refreshSMARTIfStale(now: now) }

        if metrics.contains(.disk), let capacity = DiskSampler.readCapacity() {
            let throughput = DiskSampler.readThroughput()
            snapshot.disk = DiskSample(
                volumes: VolumeLister.list(),
                smart: smart,
                used: capacity.used,
                total: capacity.total,
                readPerSecond: rate(from: previousDisk?.read, to: throughput?.read, over: elapsed),
                writePerSecond: rate(
                    from: previousDisk?.written, to: throughput?.written, over: elapsed)
            )
            previousDisk = throughput
        }

        if metrics.contains(.network), let counters = NetworkSampler.read() {
            networkDownloaded.add(counter: counters.received)
            networkUploaded.add(counter: counters.sent)
            snapshot.network = NetworkSample(
                downloadPerSecond: rate(
                    from: previousNetwork?.received, to: counters.received, over: elapsed),
                uploadPerSecond: rate(from: previousNetwork?.sent, to: counters.sent, over: elapsed),
                sessionDownloaded: networkDownloaded.total,
                sessionUploaded: networkUploaded.total
            )
            previousNetwork = counters
        }

        // One registry pass for both: Battery and Power are separate rows but the same hardware.
        if metrics.contains(.battery) || metrics.contains(.power),
           let power = PowerSourceReader.read() {
            if metrics.contains(.battery) { snapshot.battery = power.battery }
            if metrics.contains(.power) { snapshot.power = power.power }
        }

        previousSampledAt = now
        return snapshot
    }

    /// Publishes a snapshot and extends the history windows.
    @MainActor
    func apply(_ snapshot: SystemSnapshot) {
        var history = reading.history
        for kind in enabledMetrics {
            var window = history[kind] ?? MetricHistory()
            // Appends nil for a reading that isn't available, which the window keeps as a gap.
            window.append(snapshot.chartValue(for: kind))
            history[kind] = window
        }

        let updated = MonitorReading(snapshot: snapshot, history: history)
        // With metrics enabled the history always grows, so this guard only bites when nothing is
        // being watched at all — which is exactly when churning the UI would be pure waste.
        guard updated != reading else { return }
        objectWillChange.send()
        reading = updated
    }

    /// What appears beside the Sarvkrit icon, as the single string the menu bar can render.
    ///
    /// Empty rather than nil when there is nothing to say, which `MenuBarIconState.trailingText`
    /// treats as absent — so Keep Awake's countdown keeps the slot to itself with no dangling
    /// separator.
    ///
    /// Gated on `isRunning` as well as the preference. Without that the label read "CPU —" for a
    /// feature the user had switched off: the snapshot is empty, so every metric formats as a
    /// placeholder, and a placeholder claims a reading is merely unavailable rather than not being
    /// taken at all. A switched-off feature says nothing.
    var menuBarLine: String {
        guard isRunning, showsLiveDataInMenuBar else { return "" }
        return MenuBarReadout.line(for: reading.snapshot, metrics: menuBarMetrics)
    }

    // MARK: - Timer

    private func restartTimer() {
        timer?.invalidate()
        // `.common` so it keeps firing while a menu bar panel is open — the one moment the readings
        // are actually being looked at.
        let timer = Timer(timeInterval: interval.seconds, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let token = generation
        Self.workQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.takeSnapshot()
            DispatchQueue.main.async {
                // The whole point of `generation`: this reading was gathered for a run of the
                // feature that may since have been switched off.
                guard self.generation == token, self.isRunning else { return }
                self.apply(snapshot)
            }
        }
    }

    // MARK: - Sleep

    /// `MetricRate`'s 30-second ceiling already discards anything spanning a long nap, so this
    /// covers the shorter ones — a lid closed and reopened inside the ceiling, where the elapsed
    /// time looks ordinary but the counters jumped as the network reconnected.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.discardBaselines()
        }
    }

    /// Hops to `workQueue` rather than writing directly: the baselines belong to that queue, and
    /// this is called from the main thread on wake and on every toggle.
    private static let smartInterval: TimeInterval = 300

    private func refreshSMARTIfStale(now: Date) {
        if let smartReadAt, now.timeIntervalSince(smartReadAt) < Self.smartInterval { return }
        smart = SMARTReader.readInternal()
        smartReadAt = now
    }

    private func resetSessionTotals() {
        Self.workQueue.async { [weak self] in
            self?.networkDownloaded.reset()
            self?.networkUploaded.reset()
        }
    }

    private func discardBaselines() {
        Self.workQueue.async { [weak self] in
            self?.previousCPU = nil
            self?.previousNetwork = nil
            self?.previousDisk = nil
            self?.previousSampledAt = nil
        }
    }

    private func rate(from previous: UInt64?, to current: UInt64?, over elapsed: TimeInterval?)
        -> Double? {
        guard let previous, let current, let elapsed else { return nil }
        return MetricRate.perSecond(previous: previous, current: current, elapsed: elapsed)
    }
}
