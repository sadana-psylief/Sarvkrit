import CoreAudio
import Foundation

/// Muting and reading the input device.
///
/// Extracted because two features need it — the manual switch and the privacy lock — and **its
/// failure mode is the worst one in this project: appearing to mute while the microphone stays
/// live.** Code like that should exist once.
///
/// The decisions stay in the pure `MicMuteState`; this is only the Core Audio side of them. As with
/// the rest of `AudioSystem`, nothing here may run on the main thread.
enum MicrophoneMuter {
    private static let scope = kAudioObjectPropertyScopeInput

    /// What the current input device is doing.
    struct Reading: Equatable {
        var isMuted: Bool
        /// The device supports neither mute nor volume, so we genuinely cannot silence it.
        var isUnsupported: Bool
        var deviceName: String?
        /// False when there is no input device at all.
        var hasDevice: Bool
    }

    static func read() -> Reading {
        guard let device = AudioSystem.defaultDevice(.input) else {
            return Reading(isMuted: false, isUnsupported: true, deviceName: nil, hasDevice: false)
        }
        let mute = AudioSystem.mute(device, scope: scope)
        let volume = AudioSystem.volume(device, scope: scope)
        return Reading(
            isMuted: MicMuteState.isMuted(muteProperty: mute, volume: volume),
            isUnsupported: !AudioSystem.isSettable(device, kAudioDevicePropertyMute, scope: scope)
                && !AudioSystem.isSettable(device, kAudioDevicePropertyVolumeScalar, scope: scope),
            deviceName: AudioSystem.devices().first { $0.id == device }?.name,
            hasDevice: true
        )
    }

    /// Applies a mute, choosing the mechanism the device actually supports.
    ///
    /// - Parameter restoreVolume: the level to put back when unmuting, if we previously zeroed it.
    /// - Returns: the level worth remembering for a later unmute, when we muted by zeroing. Nil
    ///   when nothing needs remembering — the caller persists it.
    @discardableResult
    static func setMuted(_ muted: Bool, restoreVolume: Float?) -> Float? {
        guard let device = AudioSystem.defaultDevice(.input) else { return nil }

        let capability = MicMuteState.Capability(
            muteIsSettable: AudioSystem.isSettable(device, kAudioDevicePropertyMute, scope: scope),
            volumeIsSettable: AudioSystem.isSettable(
                device, kAudioDevicePropertyVolumeScalar, scope: scope),
            currentVolume: AudioSystem.volume(device, scope: scope)
        )

        // Read what to restore *before* changing anything, or the value is already zero.
        let remembered = muted
            ? MicMuteState.volumeToRemember(capability: capability)
            : restoreVolume

        switch MicMuteState.action(muting: muted, capability: capability, restoreVolume: remembered) {
        case .setMute(let value):
            AudioSystem.setMute(value, on: device, scope: scope)
            return nil
        case .setVolume(let value):
            AudioSystem.setVolume(value, on: device, scope: scope)
            return muted ? remembered : nil
        case .unsupported:
            return nil
        }
    }

    /// Whether anything is currently listening — true while an app holds the input device open.
    ///
    /// Independent of muting: an app can be recording silence, which is exactly what the privacy
    /// warning is for.
    static func isInUse() -> Bool {
        guard let device = AudioSystem.defaultDevice(.input) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
