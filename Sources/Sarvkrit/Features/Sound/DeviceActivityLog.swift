import Foundation

/// A record of when the camera or microphone was in use, and the decision of when to say so.
///
/// **Debouncing is the point.** An app toggling the camera during a call — which video apps do
/// routinely, on every layout change — would otherwise produce a stream of warnings, and a warning
/// that appears twenty times is one nobody reads the twenty-first time.
///
/// Pure, so the coalescing is a table rather than something judged by sitting in a video call.
struct DeviceActivityLog {

    enum Device: String, Codable, Equatable {
        case camera, microphone

        var title: String { self == .camera ? "Camera" : "Microphone" }
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var device: Device
        var startedAt: Date
        var endedAt: Date?

        var isOngoing: Bool { endedAt == nil }
    }

    /// How long a device must stay off before turning on again counts as a new session worth
    /// announcing. Below this, it is the same use flickering.
    static let coalescingWindow: TimeInterval = 20

    /// How many sessions to keep. The pane shows recent history, not an audit trail.
    static let limit = 20

    private(set) var entries: [Entry] = []

    enum Announcement: Equatable {
        case none
        /// Worth telling the user about.
        case turnedOn(Device)
    }

    /// Records a transition and says whether it deserves a warning.
    mutating func record(_ device: Device, isOn: Bool, at time: Date) -> Announcement {
        if isOn {
            // Already ongoing: nothing changed.
            if entries.contains(where: { $0.device == device && $0.isOngoing }) { return .none }

            let resumedRecently = entries.first { entry in
                entry.device == device
                    && entry.endedAt.map { time.timeIntervalSince($0) < Self.coalescingWindow } == true
            } != nil

            if resumedRecently, let index = entries.firstIndex(where: { $0.device == device }) {
                // Reopen the last session rather than starting a new one, so a flickering camera
                // reads as one use.
                entries[index].endedAt = nil
                return .none
            }

            entries.insert(Entry(device: device, startedAt: time), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
            return .turnedOn(device)
        }

        guard let index = entries.firstIndex(where: { $0.device == device && $0.isOngoing }) else {
            return .none
        }
        entries[index].endedAt = time
        return .none
    }

    var isCameraOn: Bool {
        entries.contains { $0.device == .camera && $0.isOngoing }
    }

    var isMicrophoneInUse: Bool {
        entries.contains { $0.device == .microphone && $0.isOngoing }
    }

    mutating func clear() { entries.removeAll() }
}
