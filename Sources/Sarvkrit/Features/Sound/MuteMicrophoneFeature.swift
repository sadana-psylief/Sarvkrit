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
            guard let self, let device = AudioSystem.defaultDevice(.input) else { return }
            let scope = kAudioObjectPropertyScopeInput

            let capability = MicMuteState.Capability(
                muteIsSettable: AudioSystem.isSettable(device, kAudioDevicePropertyMute, scope: scope),
                volumeIsSettable: AudioSystem.isSettable(
                    device, kAudioDevicePropertyVolumeScalar, scope: scope),
                currentVolume: AudioSystem.volume(device, scope: scope)
            )

            // Read what to restore *before* changing anything, or the value is already zero.
            let remembered = muted
                ? MicMuteState.volumeToRemember(capability: capability)
                : self.restoreVolume

            switch MicMuteState.action(
                muting: muted, capability: capability, restoreVolume: remembered
            ) {
            case .setMute(let value):
                AudioSystem.setMute(value, on: device, scope: scope)
            case .setVolume(let value):
                if muted, let remembered { DispatchQueue.main.async { self.restoreVolume = remembered } }
                AudioSystem.setVolume(value, on: device, scope: scope)
            case .unsupported:
                break
            }
            self.readState()
        }
    }

    /// Re-reads the device's actual state rather than tracking what we asked for — muting can also
    /// happen in System Settings or on the hardware itself.
    private func readState() {
        Self.workQueue.async { [weak self] in
            guard let self else { return }
            guard let device = AudioSystem.defaultDevice(.input) else {
                DispatchQueue.main.async { self.apply(muted: false, unsupported: true, name: nil) }
                return
            }
            let scope = kAudioObjectPropertyScopeInput
            let mute = AudioSystem.mute(device, scope: scope)
            let volume = AudioSystem.volume(device, scope: scope)
            let unsupported =
                !AudioSystem.isSettable(device, kAudioDevicePropertyMute, scope: scope)
                && !AudioSystem.isSettable(device, kAudioDevicePropertyVolumeScalar, scope: scope)
            let name = AudioSystem.devices().first { $0.id == device }?.name

            let muted = MicMuteState.isMuted(muteProperty: mute, volume: volume)
            DispatchQueue.main.async {
                self.apply(muted: muted, unsupported: unsupported, name: name)
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
