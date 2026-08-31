import Foundation

/// How to mute an input device, and how to put it back.
///
/// **The fallback chain is the whole feature**, because `kAudioDevicePropertyMute` is not
/// universally settable. The built-in microphone and line-in support it; plenty of USB interfaces
/// don't, and setting it on a Bluetooth device has been broken since Monterey. A feature that only
/// knew how to set the mute property would appear to work and leave the microphone live — the worst
/// possible failure for this particular feature.
///
/// So: mute if we can, otherwise turn the volume to zero, and either way remember enough to restore
/// what was there rather than jumping to 100%.
enum MicMuteState {

    /// What the device supports, read before deciding.
    struct Capability: Equatable {
        var muteIsSettable: Bool
        var volumeIsSettable: Bool
        /// The device's current input volume, if it reports one.
        var currentVolume: Float?
    }

    enum Action: Equatable {
        case setMute(Bool)
        /// Set the input volume, restoring a remembered level when unmuting.
        case setVolume(Float)
        /// Neither mechanism is available — the device genuinely cannot be muted by us.
        case unsupported
    }

    /// - Parameter restoreVolume: what the volume was before we zeroed it, if we did.
    static func action(
        muting: Bool,
        capability: Capability,
        restoreVolume: Float?
    ) -> Action {
        if capability.muteIsSettable { return .setMute(muting) }
        guard capability.volumeIsSettable else { return .unsupported }

        guard muting else {
            // Restore what was there. Falling back to full volume would quietly turn someone's
            // carefully-set input gain up to maximum, which is its own kind of broken.
            return .setVolume(restoreVolume ?? 1)
        }
        return .setVolume(0)
    }

    /// The volume to remember before muting, so unmuting can put it back.
    ///
    /// Nil when we're about to use the mute property — that doesn't disturb the volume, so there is
    /// nothing to restore. Also nil for a volume already at zero: remembering that would mean
    /// unmuting to silence, which looks exactly like the feature failing.
    static func volumeToRemember(capability: Capability) -> Float? {
        guard !capability.muteIsSettable else { return nil }
        guard let current = capability.currentVolume, current > 0 else { return nil }
        return current
    }

    /// Whether the device is currently muted, from whichever signal applies.
    static func isMuted(muteProperty: Bool?, volume: Float?) -> Bool {
        if let muteProperty { return muteProperty }
        guard let volume else { return false }
        return volume <= 0.0001
    }
}
