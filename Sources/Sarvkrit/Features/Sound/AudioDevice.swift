import CoreAudio
import Foundation

/// One audio device, as a value.
///
/// Deliberately a plain struct rather than a live Core Audio object: everything that decides
/// *which* device to use is then pure and testable, and the only thing that has to touch Core Audio
/// is reading this list and setting the default.
struct AudioDevice: Identifiable, Equatable, Hashable {
    /// `AudioObjectID`. Stable while the device is connected; **not** stable across reconnects, so
    /// it must never be persisted — see `uid`.
    let id: AudioObjectID
    /// The device's own persistent identifier, which survives unplugging. This is what a "preferred
    /// device" setting stores.
    let uid: String
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
    /// Aggregate and virtual devices are created by other audio software. Offering to switch to
    /// somebody's private aggregate is a good way to break their setup.
    let isAggregate: Bool

    enum Kind: String, Codable, CaseIterable, Identifiable {
        case output, input
        var id: String { rawValue }
        var title: String { self == .output ? "Output" : "Input" }
    }

    func supports(_ kind: Kind) -> Bool {
        kind == .output ? hasOutput : hasInput
    }
}

/// Choosing between devices. Pure, so the awkward cases — the current device being unplugged
/// mid-cycle, a preferred device that isn't connected — are a test table rather than something you
/// discover by pulling cables.
enum AudioDeviceList {

    /// The devices worth offering for a given kind, in a stable order.
    ///
    /// Aggregates are excluded: they are other tools' plumbing, not somewhere a person means to
    /// send their audio.
    static func selectable(from devices: [AudioDevice], kind: AudioDevice.Kind) -> [AudioDevice] {
        devices
            .filter { $0.supports(kind) && !$0.isAggregate }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The next device to cycle to.
    ///
    /// Returns nil when there is nowhere to go — no devices, or only the one already in use — so a
    /// shortcut press does nothing rather than something surprising.
    static func next(
        after current: AudioObjectID?,
        in devices: [AudioDevice],
        kind: AudioDevice.Kind
    ) -> AudioDevice? {
        let options = selectable(from: devices, kind: kind)
        guard options.count > 1 else { return options.first(where: { $0.id != current }) }

        // A current device that isn't in the list — just unplugged, or an aggregate — means we have
        // no position to advance from, so start at the beginning rather than refusing.
        guard let index = options.firstIndex(where: { $0.id == current }) else { return options.first }
        return options[(index + 1) % options.count]
    }

    /// The preferred device, if it is currently connected.
    ///
    /// Matched by `uid`, never by `AudioObjectID` — an ID is reassigned on reconnect, so matching on
    /// it would mean "auto-switch to whatever device happens to hold that number now".
    static func preferred(
        uid: String?,
        in devices: [AudioDevice],
        kind: AudioDevice.Kind
    ) -> AudioDevice? {
        guard let uid else { return nil }
        return selectable(from: devices, kind: kind).first { $0.uid == uid }
    }

    /// Whether the preferred device has just appeared and isn't already in use — the condition for
    /// an automatic switch.
    static func shouldAutoSwitch(
        to uid: String?,
        current: AudioObjectID?,
        devices: [AudioDevice],
        kind: AudioDevice.Kind
    ) -> AudioDevice? {
        guard let target = preferred(uid: uid, in: devices, kind: kind) else { return nil }
        return target.id == current ? nil : target
    }
}
