import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// Stops the Mac going to sleep on its own.
///
/// Two mechanisms with very different characters — see `SleepAssertion` (ours, disposable) and
/// `SleepDisableFlag` (the machine's, persistent). This feature's job is mostly to keep them
/// honest about each other.
final class KeepAwakeFeature: Feature, ObservableObject {
    let id = "keep-awake"
    let category = FeatureCategory.system
    let title = "Keep Awake"
    let summary = "Stop the Mac sleeping on its own"
    let details = """
        Prevents your Mac from going to sleep by itself. Turn it off and normal sleep behaviour \
        returns immediately.

        The lid-closed option is different in kind: it changes a system-wide setting, which is why \
        macOS asks for your password. Sarvkrit starts a small background task at the same time that \
        restores normal sleep the moment Sarvkrit quits — including if it crashes — so your Mac \
        can't be left permanently awake in a bag.
        """
    let symbolName = "cup.and.saucer"
    /// No Accessibility: this touches power management, not input.
    let requirements: Set<Requirement> = []

    @Published private(set) var isRunning = false
    @Published private(set) var expiresAt: Date?
    /// True when a flag we set survived a reboot and is still on with the feature off.
    @Published private(set) var hasStrandedFlag = false
    @Published private(set) var lidClosedActive = false

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "KeepAwake")
    private let defaults: UserDefaults
    private let assertion = SleepAssertion()
    private var timer: Timer?

    private static let keepDisplayKey = "keepAwake.keepDisplayOn"
    /// Internal, not private, so the turn-off tests can arrange state through the same keys the
    /// app stores rather than keeping their own copies of the strings.
    static let lidClosedKey = "keepAwake.lidClosed"
    private static let durationKey = "keepAwake.duration"
    /// Our record that *we* were the ones who set the system flag.
    static let weSetFlagKey = "keepAwake.weSetSleepDisabled"

    /// Injected for the same reason `defaults` is: every path that changes the system flag goes
    /// through here, and a test that reached the real one would raise a root password dialog in
    /// the middle of `make test`.
    private let runPrivileged: (String) -> Bool

    init(
        defaults: UserDefaults = .standard,
        runPrivileged: @escaping (String) -> Bool = SleepDisableFlag.runPrivileged
    ) {
        self.defaults = defaults
        self.runPrivileged = runPrivileged
    }

    // MARK: - Settings

    var keepDisplayOn: Bool {
        get { defaults.bool(forKey: Self.keepDisplayKey) }
        set {
            guard newValue != keepDisplayOn else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.keepDisplayKey)
            if isRunning { assertion.acquire(keepDisplayOn: newValue) }
        }
    }

    var lidClosed: Bool {
        get { defaults.bool(forKey: Self.lidClosedKey) }
        set {
            guard newValue != lidClosed else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.lidClosedKey)
            // Split, because on and off are not symmetrical. `applyLidClosed()` sets the flag and
            // is also called from `activate()`; clearing must happen only here, where the user has
            // just asked for normal sleep back.
            if newValue { applyLidClosed() } else { clearFlagIfOurs() }
        }
    }

    var duration: KeepAwakeDuration {
        get {
            (defaults.string(forKey: Self.durationKey)).flatMap(KeepAwakeDuration.init) ?? .indefinite
        }
        set {
            guard newValue != duration else { return }
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.durationKey)
            if isRunning { restartTimer() }
        }
    }

    private var weSetFlag: Bool {
        get { defaults.bool(forKey: Self.weSetFlagKey) }
        set { defaults.set(newValue, forKey: Self.weSetFlagKey) }
    }

    // MARK: - Lifecycle

    func activate() {
        isRunning = true
        assertion.acquire(keepDisplayOn: keepDisplayOn)
        restartTimer()
        applyLidClosed()
    }

    func deactivate() {
        isRunning = false
        assertion.release()
        timer?.invalidate()
        timer = nil
        expiresAt = nil
        // The flag is deliberately NOT cleared here, and the reason is narrower than it looks.
        // Clearing needs root, and `AppState` calls this from `deinit` as well as from a toggle —
        // in the test host that is a `KeepAwakeFeature` on the real `UserDefaults.standard`, so a
        // password dialog here would interrupt `make test` on a machine where the flag happens to
        // be on, and never on CI. The user's click arrives as `userDidDisable()` instead.
        //
        // On the way out of the app nothing calls this at all: the watchdog notices the pid is
        // gone and clears the flag within seconds. What it cannot do is notice a *toggle*, which
        // is the whole reason `userDidDisable()` exists.
        reconcile()
    }

    /// The user switched Keep Awake off. Distinct from `deactivate()` on purpose — see the comment
    /// there for what that distinction is protecting.
    func userDidDisable() {
        clearFlagIfOurs()
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(KeepAwakeDetailView(feature: self))
    }

    /// The one panel that stays on the strip while its feature is off — see
    /// `Feature.panelIsItsOwnSwitch`, which explains why.
    var panelIsItsOwnSwitch: Bool { true }

    @MainActor
    func trayPanels() -> [TrayPanel] {
        [TrayPanel(id: "keep-awake", title: "Keep Awake", symbolName: "moon.zzz") {
            KeepAwakeTrayView(feature: self)
        }]
    }

    // MARK: - The system flag

    private func applyLidClosed() {
        guard isRunning, lidClosed else {
            reconcile()
            return
        }
        let script = SleepDisableFlag.enableScript(
            pid: ProcessInfo.processInfo.processIdentifier,
            watchdogSeconds: Int(duration.watchdogSeconds)
        )
        if runPrivileged(script) {
            weSetFlag = true
            log.notice("sleep disabled system-wide, with a watchdog to restore it")
        } else {
            // Cancelled or failed — don't leave the toggle claiming something untrue.
            objectWillChange.send()
            defaults.set(false, forKey: Self.lidClosedKey)
        }
        reconcile()
    }

    /// Asks the user to restore normal sleep. Only ever called from an explicit click.
    func restoreSleep() {
        clearFlagIfOurs()
    }

    /// Puts normal sleep back, if the flag is ours to put back.
    ///
    /// Gated on `weSetFlag` because of `KeepAwakeState.action`'s `(false, true, false)` row: a flag
    /// somebody disabled sleep with by hand, in a terminal, for a reason we know nothing about, is
    /// not ours to clear. The gate also means the common case — turning off a feature that never
    /// touched the system flag — costs no password prompt at all.
    ///
    /// A refusal leaves `weSetFlag` alone deliberately. The flag is still set and still ours, so
    /// the pane must keep offering to restore it rather than forgetting it exists.
    private func clearFlagIfOurs() {
        guard weSetFlag else { reconcile(); return }
        if runPrivileged(SleepDisableFlag.disableScript()) {
            weSetFlag = false
            log.notice("normal sleep restored")
        }
        reconcile()
    }

    /// Compares what we believe against what the system reports, and updates the published state.
    ///
    /// The `pmset` read forks a subprocess and waits on it, so it must never run on the main
    /// thread: the event tap's run loop is there, and a blocking fork shows up as input latency in
    /// whatever app the user happens to be typing in. The answer is applied when it arrives, and
    /// the pane simply renders with what it already had until then.
    func reconcile() {
        let weSet = weSetFlag
        let wantsLidClosed = isRunning && lidClosed

        Self.reconcileQueue.async { [weak self] in
            let flagIsOn = SleepDisableFlag.currentState() ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                let situation = KeepAwakeState.Situation(
                    weSetIt: weSet,
                    wantsLidClosed: wantsLidClosed,
                    flagIsOn: flagIsOn
                )
                self.lidClosedActive = flagIsOn
                self.hasStrandedFlag = KeepAwakeState.showsStrandedWarning(for: situation)
                // Once the flag is genuinely gone, stop claiming ownership of it.
                if !flagIsOn { self.weSetFlag = false }
            }
        }
    }

    private static let reconcileQueue =
        DispatchQueue(label: "\(AppIdentity.bundleID).keep-awake-reconcile")

    // MARK: - Timer

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        expiresAt = nil

        guard let seconds = duration.seconds else { return }
        let deadline = Date().addingTimeInterval(seconds)
        expiresAt = deadline

        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.expire()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Releasing the assertion needs no privileges; the watchdog clears the system flag on the
    /// same deadline, so nothing here has to ask for a password.
    private func expire() {
        log.notice("keep awake expired")
        assertion.release()
        isRunning = false
        expiresAt = nil
        reconcile()
    }

    /// Whether the *machine* currently cannot sleep — the flag being on, whoever set it. Read by
    /// the menu bar icon and the panel so neither has to recombine flags and risk disagreeing.
    var systemSleepDisabled: Bool { lidClosedActive }

    /// What the menu bar should be showing right now.
    var iconState: MenuBarIconState {
        MenuBarIconState.current(
            keepAwakeRunning: isRunning, systemSleepDisabled: systemSleepDisabled)
    }

    var remainingTime: TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSinceNow)
    }
}
