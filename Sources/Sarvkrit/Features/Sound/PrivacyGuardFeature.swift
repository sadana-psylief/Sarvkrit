import AppKit
import Foundation
import SwiftUI
import os

/// Keeps the microphone off, and says when the camera comes on.
///
/// **It cannot turn the camera off, and nothing here pretends otherwise.** macOS has no public API
/// for that — Apple's own developer support says so — and every tool that appears to do it either
/// watches and warns, or sends you to System Settings. So the camera half warns, loudly and
/// immediately, and the UI copy says exactly that.
///
/// The microphone half is the substance: a lock rather than a switch.
final class PrivacyGuardFeature: Feature, ObservableObject {
    let id = "privacy-guard"
    let category = FeatureCategory.sound
    let title = "Privacy Guard"
    let summary = "Keep the mic off, watch the camera"
    let details = """
        Holds your microphone muted and tells you the moment your camera comes on.

        Each part is a separate switch. The lock puts the mute back if anything turns it off — an \
        app, System Settings, you by accident. It can also mute at login and whenever the Mac \
        sleeps or locks, so the microphone is never live while you're away.

        Sarvkrit can't switch the camera off. macOS provides no way for any app to do that, and \
        anything claiming otherwise is either using a private trick or simply showing you a \
        warning. This shows you the warning — the instant the camera starts, in the menu bar and \
        as a message, with a list of when it happened.

        Checking whether the camera is on is a question about the device. Sarvkrit never opens the \
        camera and no video ever reaches it.
        """
    let symbolName = "lock.shield"
    let requirements: Set<Requirement> = []

    @Published private(set) var isMicrophoneMuted = false
    @Published private(set) var isCameraOn = false
    @Published private(set) var isMicrophoneInUse = false
    @Published private(set) var activity = DeviceActivityLog()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "PrivacyGuard")
    private let defaults: UserDefaults
    private var guardState = PrivacyGuardState()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    /// Last known mute state, so a poll can be turned into a change.
    private var lastKnownMuted: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Settings, each its own switch

    var keepMuted: Bool {
        get { defaults.bool(forKey: Self.keepMutedKey) }
        set {
            guard newValue != keepMuted else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.keepMutedKey)
            guardState.isLocked = newValue
            if newValue { engageLock() }
        }
    }

    var muteAtLogin: Bool {
        get { defaults.bool(forKey: Self.loginKey) }
        set {
            guard newValue != muteAtLogin else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.loginKey)
        }
    }

    var warnWhenListening: Bool {
        get { defaults.object(forKey: Self.listeningKey) as? Bool ?? true }
        set {
            guard newValue != warnWhenListening else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.listeningKey)
        }
    }

    var muteOnSleep: Bool {
        get { defaults.object(forKey: Self.sleepKey) as? Bool ?? true }
        set {
            guard newValue != muteOnSleep else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.sleepKey)
        }
    }

    var warnAboutCamera: Bool {
        get { defaults.object(forKey: Self.cameraKey) as? Bool ?? true }
        set {
            guard newValue != warnAboutCamera else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.cameraKey)
        }
    }

    private static let keepMutedKey = "privacy.keepMuted"
    private static let loginKey = "privacy.muteAtLogin"
    private static let listeningKey = "privacy.warnWhenListening"
    private static let sleepKey = "privacy.muteOnSleep"
    private static let cameraKey = "privacy.warnAboutCamera"
    private static let restoreKey = "privacy.restoreVolume"

    private var restoreVolume: Float? {
        get {
            let stored = defaults.float(forKey: Self.restoreKey)
            return stored > 0 ? stored : nil
        }
        set { defaults.set(newValue ?? 0, forKey: Self.restoreKey) }
    }

    // MARK: - Lifecycle

    func activate() {
        guardState.isLocked = keepMuted
        lastKnownMuted = nil

        if muteAtLogin || keepMuted { mute(reason: "at login") }

        let timer = Timer(timeInterval: CameraMonitor.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observeSleepAndLock()
        poll()
    }

    func deactivate() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
            self.lockObserver = nil
        }
        lastKnownMuted = nil
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(PrivacyGuardDetailView(feature: self))
    }

    // MARK: - Polling

    /// One timer for both devices and the lock. Each tick is three cheap property reads.
    private func poll() {
        Self.workQueue.async { [weak self] in
            guard let self else { return }
            let reading = MicrophoneMuter.read()
            let micInUse = MicrophoneMuter.isInUse()
            let cameraOn = CameraMonitor.isAnyCameraOn()

            DispatchQueue.main.async {
                self.apply(muted: reading.isMuted, micInUse: micInUse, cameraOn: cameraOn)
            }
        }
    }

    @MainActor
    private func apply(muted: Bool, micInUse: Bool, cameraOn: Bool) {
        if isMicrophoneMuted != muted { isMicrophoneMuted = muted }

        // Turn the poll into a change, so the lock reasons about transitions rather than levels.
        if lastKnownMuted != muted {
            let change: PrivacyGuardState.Change = muted ? .becameMuted : .becameUnmuted
            lastKnownMuted = muted
            if guardState.handle(change) == .reassertMute {
                log.notice("microphone was unmuted while locked — putting it back")
                mute(reason: "the lock")
            }
        }

        record(.camera, isOn: cameraOn && warnAboutCamera)
        record(.microphone, isOn: micInUse && warnWhenListening)

        if isCameraOn != activity.isCameraOn { isCameraOn = activity.isCameraOn }
        if isMicrophoneInUse != activity.isMicrophoneInUse {
            isMicrophoneInUse = activity.isMicrophoneInUse
        }
    }

    @MainActor
    private func record(_ device: DeviceActivityLog.Device, isOn: Bool) {
        switch activity.record(device, isOn: isOn, at: Date()) {
        case .none:
            break
        case .turnedOn(let device):
            // Deliberately says only what is true. macOS does not report which app holds the
            // camera, and a guessed app name would be a lie at exactly the moment someone is
            // relying on this.
            ToastPresenter.shared.show(
                device == .camera ? "Camera is on" : "Something is using the microphone",
                symbolName: device == .camera ? "video.fill" : "mic.fill"
            )
        }
    }

    // MARK: - Muting

    private func mute(reason: String) {
        guardState.willAssertMute()
        Self.workQueue.async { [weak self] in
            guard let self else { return }
            let remembered = MicrophoneMuter.setMuted(true, restoreVolume: self.restoreVolume)
            if let remembered { DispatchQueue.main.async { self.restoreVolume = remembered } }
            self.log.notice("microphone muted (\(reason, privacy: .public))")
            self.poll()
        }
    }

    /// Reads the device off the main thread, like every other Core Audio call here.
    private func engageLock() {
        Self.workQueue.async { [weak self] in
            guard let self else { return }
            let reading = MicrophoneMuter.read()
            guard PrivacyGuardState.actionOnLockEngaged(
                currentlyMuted: reading.isMuted
            ) == .reassertMute else { return }
            self.mute(reason: "the lock was switched on")
        }
    }

    // MARK: - Sleep and lock

    private func observeSleepAndLock() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self, self.muteOnSleep else { return }
                    self.mute(reason: "the Mac is sleeping")
                }
            )
        }

        // Screen lock has no NSWorkspace notification; it arrives as a distributed one. The app
        // already uses `DistributedNotificationCenter` in `SingleInstance`.
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.muteOnSleep else { return }
            self.mute(reason: "the screen locked")
        }
    }

    private static let workQueue = DispatchQueue(label: "\(AppIdentity.bundleID).privacy-guard")
}
