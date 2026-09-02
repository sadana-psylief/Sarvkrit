import CoreMediaIO
import Foundation

/// Whether any camera is currently on.
///
/// **Reads state; never opens a camera.** There is no capture session here and no video ever
/// arrives — the whole feature is a question about a device, asked repeatedly.
///
/// Polled rather than observed. A `kCMIODevicePropertyDeviceIsRunningSomewhere` listener is
/// documented as firing spuriously on Apple Silicon, including when unrelated apps merely launch,
/// and a privacy warning that cries wolf is worse than none. Half a second is fast enough that the
/// warning still feels immediate.
enum CameraMonitor {

    static let pollInterval: TimeInterval = 0.5

    /// True while any camera is in use.
    static func isAnyCameraOn() -> Bool {
        devices().contains(where: isRunning)
    }

    static func cameraCount() -> Int { devices().count }

    private static func devices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value
        ) == noErr else { return false }
        return value != 0
    }
}
