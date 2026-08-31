import CoreAudio
import Foundation
import os

/// The thin layer over Core Audio: enumerate devices, read and set the defaults.
///
/// **Nothing here may be called from the main thread.** Property reads block on `coreaudiod`, and
/// the main thread is where the event tap's run loop lives — the same rule `KeepAwakeFeature`
/// records for its `pmset` fork, and for the same reason: a blocking call there is felt as input
/// latency in whatever app the user is typing in. Callers hop to a queue first.
enum AudioSystem {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Sound")

    // MARK: - Enumerating

    static func devices() -> [AudioDevice] {
        objectIDs(for: kAudioHardwarePropertyDevices, on: AudioObjectID(kAudioObjectSystemObject))
            .compactMap(describe)
    }

    private static func describe(_ id: AudioObjectID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName)
        else { return nil }

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            hasOutput: hasStreams(id, scope: kAudioObjectPropertyScopeOutput),
            hasInput: hasStreams(id, scope: kAudioObjectPropertyScopeInput),
            isAggregate: transportType(id) == kAudioDeviceTransportTypeAggregate
        )
    }

    /// A device belongs to a scope only if it actually carries channels there. Plenty of devices
    /// advertise both and have streams in only one.
    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    // MARK: - Defaults

    static func defaultDevice(_ kind: AudioDevice.Kind) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kind == .output
                ? kAudioHardwarePropertyDefaultOutputDevice
                : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        ) == noErr else { return nil }
        return id == 0 ? nil : id
    }

    @discardableResult
    static func setDefaultDevice(_ id: AudioObjectID, kind: AudioDevice.Kind) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kind == .output
                ? kAudioHardwarePropertyDefaultOutputDevice
                : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &value
        )
        if status != noErr {
            log.error("could not set the default \(kind.rawValue, privacy: .public) device: \(status)")
        }
        return status == noErr
    }

    // MARK: - Input mute and volume

    static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func mute(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    @discardableResult
    static func setMute(_ muted: Bool, on id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    static func volume(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    @discardableResult
    static func setVolume(_ volume: Float, on id: AudioObjectID,
                          scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = max(0, min(1, volume))
        return AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value
        ) == noErr
    }

    // MARK: - Reading helpers

    private static func objectIDs(
        for selector: AudioObjectPropertySelector, on object: AudioObjectID
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func string(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String
    }

    private static func transportType(_ id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }
}
