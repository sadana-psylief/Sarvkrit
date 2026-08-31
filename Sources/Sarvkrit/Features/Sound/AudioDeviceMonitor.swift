import CoreAudio
import Foundation

/// Watches the machine's audio devices and reports changes.
///
/// Written once because three features need it: the switcher redraws its list, auto-switch reacts
/// to a preferred device appearing, and the Music blocker uses a device arriving as the signal that
/// a launch wasn't the user's doing.
///
/// Core Audio delivers its callbacks on a queue we choose, and enumeration blocks on `coreaudiod`,
/// so **the whole of this stays off the main thread** — the main thread hosts the event tap's run
/// loop, where a blocking call becomes input latency system-wide.
final class AudioDeviceMonitor {
    /// Called on `queue` — never main — whenever the device list or a default device changes.
    var onChange: (([AudioDevice]) -> Void)?

    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).audio-devices")
    private var isListening = false

    /// The listener block, retained so it can be removed. Core Audio requires the *same* block
    /// object to deregister, so keeping it is not optional.
    private var listener: AudioObjectPropertyListenerBlock?

    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isListening else { return }
            self.isListening = true

            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.onChange?(AudioSystem.devices())
            }
            self.listener = listener

            for selector in Self.watchedSelectors {
                var address = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, self.queue, listener
                )
            }

            // Seed, so a caller has the current list without waiting for something to change.
            self.onChange?(AudioSystem.devices())
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.isListening, let listener = self.listener else { return }
            for selector in Self.watchedSelectors {
                var address = Self.address(selector)
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, self.queue, listener
                )
            }
            self.listener = nil
            self.isListening = false
        }
    }

    /// Reads the current state without waiting for a change.
    func refresh() {
        queue.async { [weak self] in
            self?.onChange?(AudioSystem.devices())
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    deinit {
        // A listener outliving its owner calls into a dead closure — the same hazard
        // `EventTapService` and `ShelfHotkey` each guard in their own `deinit`.
        stop()
    }
}
