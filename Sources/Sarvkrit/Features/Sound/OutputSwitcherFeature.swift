import AppKit
import Carbon.HIToolbox
import CoreAudio
import Foundation
import SwiftUI

/// Switch which device the Mac plays through, and listens with.
///
/// Needs no permission: `kAudioHardwarePropertyDefaultOutputDevice` is device control, not capture,
/// and is not TCC-gated. The cycle shortcut uses Carbon rather than the event tap for the same
/// reason the Shelf's does — `RegisterEventHotKey` needs no Accessibility.
final class OutputSwitcherFeature: Feature, ObservableObject {
    let id = "audio-switcher"
    let category = FeatureCategory.sound
    let title = "Audio Devices"
    let summary = "Switch output and input from the menu bar"
    let details = """
        Pick which device your Mac plays through and listens with, without opening System Settings. \
        The current one is ticked; click another to switch.

        ⌃⌥O steps to the next output device, which is quicker than choosing from a list when you're \
        just moving between speakers and headphones.

        You can also name a preferred device for each. Whenever it's connected, Sarvkrit switches \
        to it — so plugging your headphones in puts the sound where you expect it.

        This needs no permissions at all.
        """
    let symbolName = "hifispeaker.and.homepod"
    var shortcutHint: String? { "⌃⌥O" }
    let requirements: Set<Requirement> = []

    /// The current device list and defaults, published for the tray and the pane.
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var currentOutput: AudioObjectID?
    @Published private(set) var currentInput: AudioObjectID?

    private let monitor = AudioDeviceMonitor()
    private let hotkey = GlobalHotkey(id: GlobalHotkey.ID.audioCycle)
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Settings

    /// The preferred device is stored by **uid, never by `AudioObjectID`** — an ID is reassigned on
    /// reconnect, so storing one would mean auto-switching to whatever device happens to hold that
    /// number afterwards.
    func preferredUID(for kind: AudioDevice.Kind) -> String? {
        defaults.string(forKey: Self.preferredKey(kind))
    }

    func setPreferredUID(_ uid: String?, for kind: AudioDevice.Kind) {
        guard uid != preferredUID(for: kind) else { return }
        objectWillChange.send()
        defaults.set(uid, forKey: Self.preferredKey(kind))
        refresh()
    }

    var cycleShortcutEnabled: Bool {
        get { defaults.object(forKey: Self.cycleKey) as? Bool ?? true }
        set {
            guard newValue != cycleShortcutEnabled else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.cycleKey)
            applyHotkey()
        }
    }

    var autoSwitchEnabled: Bool {
        get { defaults.object(forKey: Self.autoSwitchKey) as? Bool ?? true }
        set {
            guard newValue != autoSwitchEnabled else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.autoSwitchKey)
        }
    }

    private static func preferredKey(_ kind: AudioDevice.Kind) -> String {
        "sound.preferred.\(kind.rawValue)"
    }
    private static let cycleKey = "sound.cycleShortcut"
    private static let autoSwitchKey = "sound.autoSwitch"

    // MARK: - Lifecycle

    private var isRunning = false

    func activate() {
        isRunning = true
        monitor.onChange = { [weak self] devices in
            // Arrives on the monitor's queue; published state is read by SwiftUI.
            DispatchQueue.main.async { self?.apply(devices) }
        }
        monitor.start()
        applyHotkey()
    }

    func deactivate() {
        isRunning = false
        monitor.stop()
        monitor.onChange = nil
        hotkey.unregister()
    }

    func refresh() { monitor.refresh() }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(SoundDetailView(feature: self))
    }

    /// Contributes to the shared Sound panel rather than owning one.
    ///
    /// Picking an output device and setting an app's volume are one screen to anyone using them;
    /// two tabs would be an implementation detail — that Sarvkrit models them as separate features
    /// — leaking into the menu. `TrayPanel.merged(_:)` collapses everything declaring this id.
    @MainActor
    func trayPanels() -> [TrayPanel] {
        [TrayPanel(id: "sound", title: "Sound", symbolName: "slider.horizontal.3") {
            AudioDeviceTrayView(feature: self)
        }]
    }

    // MARK: - Switching

    func select(_ device: AudioDevice, kind: AudioDevice.Kind) {
        Self.workQueue.async { [weak self] in
            AudioSystem.setDefaultDevice(device.id, kind: kind)
            self?.monitor.refresh()
        }
    }

    @MainActor
    func cycle(_ kind: AudioDevice.Kind = .output) {
        let current = kind == .output ? currentOutput : currentInput
        guard let next = AudioDeviceList.next(after: current, in: devices, kind: kind) else { return }
        select(next, kind: kind)
        // Says which device it landed on — a shortcut that silently changes where your audio goes
        // is indistinguishable from it not working.
        ToastPresenter.shared.show(next.name, symbolName: "hifispeaker")
    }

    func selectable(_ kind: AudioDevice.Kind) -> [AudioDevice] {
        AudioDeviceList.selectable(from: devices, kind: kind)
    }

    func current(_ kind: AudioDevice.Kind) -> AudioObjectID? {
        kind == .output ? currentOutput : currentInput
    }

    // MARK: - Reacting to changes

    @MainActor
    private func apply(_ devices: [AudioDevice]) {
        self.devices = devices
        currentOutput = AudioSystem.defaultDevice(.output)
        currentInput = AudioSystem.defaultDevice(.input)
        guard autoSwitchEnabled else { return }

        for kind in AudioDevice.Kind.allCases {
            guard let target = AudioDeviceList.shouldAutoSwitch(
                to: preferredUID(for: kind),
                current: current(kind),
                devices: devices,
                kind: kind
            ) else { continue }

            Self.workQueue.async { AudioSystem.setDefaultDevice(target.id, kind: kind) }
            ToastPresenter.shared.show("Switched to \(target.name)", symbolName: "hifispeaker")
        }
    }

    private func applyHotkey() {
        guard isRunning, cycleShortcutEnabled else {
            hotkey.unregister()
            return
        }
        hotkey.register(keyCode: UInt32(kVK_ANSI_O)) { [weak self] in
            DispatchQueue.main.async { self?.cycle(.output) }
        }
    }

    /// Core Audio writes block on `coreaudiod`, so they never run on main — the event tap's run
    /// loop is there.
    private static let workQueue = DispatchQueue(label: "\(AppIdentity.bundleID).sound")
}
