import AppKit
import CoreAudio
import Foundation

/// An app that Core Audio knows about, and whether it is making sound right now.
struct AudioProcess: Identifiable, Equatable {
    /// The Core Audio process object, not a pid.
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    /// True while the process is actually playing. The mixer lists only these — a mixer is for
    /// what you can hear.
    let isPlaying: Bool
}

/// Reading the list of audio processes.
///
/// Off the main thread, like the rest of `AudioSystem`.
enum AudioProcesses {

    static func current() -> [AudioProcess] {
        objectIDs().compactMap(describe)
    }

    private static func describe(_ id: AudioObjectID) -> AudioProcess? {
        guard let bundleID = string(id, kAudioProcessPropertyBundleID), !bundleID.isEmpty
        else { return nil }

        let pid = self.pid(id)
        // Our own audio is not something to offer the user a slider for.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        return AudioProcess(
            id: id,
            pid: pid,
            bundleID: bundleID,
            name: displayName(bundleID: bundleID, pid: pid),
            isPlaying: boolean(id, kAudioProcessPropertyIsRunningOutput)
        )
    }

    /// The name a person would recognise, which Core Audio doesn't provide — it knows bundle ids
    /// and pids only.
    private static func displayName(bundleID: String, pid: pid_t) -> String {
        if let running = NSRunningApplication(processIdentifier: pid),
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private static func objectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func pid(_ id: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
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

    private static func boolean(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
