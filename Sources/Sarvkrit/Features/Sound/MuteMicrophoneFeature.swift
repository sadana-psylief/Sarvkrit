import AppKit
import Carbon.HIToolbox
import CoreAudio
import Foundation
import SwiftUI

/// Mutes the microphone system-wide.
///
/// Needs no permission: setting a device's mute or volume is control, not capture — we never read a
/// sample. The shortcut goes through Carbon for the same reason.
///
/// **What it can't do, stated plainly because the pane says so too:** this mutes the *device*, so an
/// app that manages its own mute — Zoom, Teams, Meet — will still show itself as unmuted. Their
/// button and this one are two different switches on the same wire.
final class MuteMicrophoneFeature: Feature, ObservableObject {
    let id = "mute-microphone"
    let category = FeatureCategory.sound
    let title = "Mute Microphone"
    let summary = "Silence the mic from the menu bar"
    let details = """
        Mutes your microphone at the device, so nothing can hear it. ⌃⌥M toggles it, and the menu \
        bar icon changes while it's muted — a mute you can't see is how people end up talking to \
        nobody.

        Some microphones don't support being muted directly, in which case Sarvkrit turns the input \
        level to zero instead and puts it back exactly where it was when you unmute.

        This mutes the device itself, so apps with their own mute button — Zoom, Teams — will still \
        show themselves as unmuted. Theirs and this are two switches on the same wire.

        No permissions needed: muting is device control, not listening.
        """
    let symbolName = "mic.slash"
    var shortcutHint: String? { "⌃⌥M" }
    let requirements: Set<Requirement> = []

    @Published private(set) var isMuted = false
    /// True when the current input device supports neither mute nor volume, so the pane can say so
    /// rather than offering a switch that does nothing.
    @Published private(set) var isUnsupported = false
    @Published private(set) var deviceName: String?

    private let monitor = AudioDeviceMonitor()
    private let hotkey = GlobalHotkey(id: GlobalHotkey.ID.micMute)
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shortcutEnabled: Bool {
        get { defaults.object(forKey: Self.shortcutKey) as? Bool ?? true }
        set {
            guard newValue != shortcutEnabled else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.shortcutKey)
            applyHotkey()
        }
    }

    /// The level to put back on unmute, when we muted by zeroing the volume.
    private var restoreVolume: Float? {
        get {
            let stored = defaults.float(forKey: Self.restoreKey)
            return stored > 0 ? stored : nil
        }
        set { defaults.set(newValue ?? 0, forKey: Self.restoreKey) }
    }

    private static let shortcutKey = "sound.micShortcut"
    private static let restoreKey = "sound.micRestoreVolume"

    // MARK: - Lifecycle

    private var isRunning = false

    func activate() {
        isRunning = true
        monitor.onChange = { [weak self] _ in self?.readState() }
        monitor.start()
        applyHotkey()
        readState()
    }

    func deactivate() {
        isRunning = false
        monitor.stop()
        monitor.onChange = nil
        hotkey.unregister()
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(MuteMicrophoneDetailView(feature: self))
    }

    // MARK: - Muting

    @MainActor
    func toggle() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        Self.workQueue.async { [weak self] in
            guard let self else { return }
            // The mechanism lives in `MicrophoneMuter`, shared with the privacy lock. Its failure
            // mode -- looking muted while the mic stays live -- is the worst in this project, so it
            // exists once rather than in each feature that needs it.
            let remembered = MicrophoneMuter.setMuted(muted, restoreVolume: self.restoreVolume)
            if let remembered { DispatchQueue.main.async { self.restoreVolume = remembered } }
            self.readState()
        }
    }

    /// Re-reads the device's actual state rather than tracking what we asked for — muting can also
    /// happen in System Settings, on the hardware, or from the privacy lock.
    private func readState() {
        Self.workQueue.async { [weak self] in
            guard let self else { return }
            let reading = MicrophoneMuter.read()
            DispatchQueue.main.async {
                self.apply(
                    muted: reading.isMuted,
                    unsupported: reading.isUnsupported,
                    name: reading.deviceName
                )
            }
        }
    }

    @MainActor
    private func apply(muted: Bool, unsupported: Bool, name: String?) {
        if isMuted != muted { isMuted = muted }
        if isUnsupported != unsupported { isUnsupported = unsupported }
        if deviceName != name { deviceName = name }
    }

    private func applyHotkey() {
        guard isRunning, shortcutEnabled else {
            hotkey.unregister()
            return
        }
        hotkey.register(keyCode: UInt32(kVK_ANSI_M)) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
    }

    private static let workQueue = DispatchQueue(label: "\(AppIdentity.bundleID).mic-mute")
}
