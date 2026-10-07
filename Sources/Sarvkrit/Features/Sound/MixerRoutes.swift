import Foundation

/// Which output each app has been sent to, remembered by bundle ID.
///
/// The same shape as `MixerLevels`, for the same reasons: bundle ID because a pid dies with the
/// app, and pure and injectable so the rules are a test table.
///
/// A route stores the device's **UID**, never its `AudioObjectID` — see `AudioDevice.uid` — and
/// its name, so a route to AirPods that are in their case can still be shown as "AirPods" rather
/// than disappearing from the list. The route is kept while the device is away: the point is that
/// Spotify goes back to the AirPods when they come back, without the user doing it again.
struct MixerRoutes {
    struct Route: Equatable {
        let uid: String
        let name: String
    }

    /// Everything the user has sent somewhere other than the system output.
    private(set) var routes: [String: Route]

    private let defaults: UserDefaults
    private static let key = "sound.mixerRoutes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: [String: String]] ?? [:]
        routes = stored.compactMapValues { entry in
            guard let uid = entry["uid"], let name = entry["name"] else { return nil }
            return Route(uid: uid, name: name)
        }
    }

    /// Nil means "the system output" — an app the user has never routed follows the default device
    /// exactly as it would without this feature.
    func route(for bundleID: String) -> Route? {
        routes[bundleID]
    }

    /// Nil puts the app back on the system output, which is the absence of a route rather than a
    /// route to whatever the default happens to be right now.
    mutating func setRoute(_ route: Route?, for bundleID: String) {
        guard routes[bundleID] != route else { return }
        routes[bundleID] = route
        save()
    }

    mutating func reset(_ bundleID: String) {
        setRoute(nil, for: bundleID)
    }

    mutating func resetAll() {
        guard !routes.isEmpty else { return }
        routes.removeAll()
        save()
    }

    private func save() {
        defaults.set(
            routes.mapValues { ["uid": $0.uid, "name": $0.name] },
            forKey: Self.key
        )
    }
}

/// Which apps get a tap, and which output each tap plays on.
///
/// Pure, so the cases you'd otherwise only meet by taking AirPods out mid-song are a table — see
/// `MixerPlanTests`.
enum MixerPlan {

    /// Bundle ID → the UID of the output that app's tap should play on.
    ///
    /// An app is tapped only when the tap would change something you can hear: it is playing, and
    /// either its level isn't full or it should be on a different device from the system output. A
    /// route to a device that isn't connected falls back to the system output — and so, at full
    /// volume, to no tap at all.
    static func desiredTaps(
        playing: [String],
        levels: MixerLevels,
        routes: MixerRoutes,
        outputs: [AudioDevice],
        defaultOutputUID: String?
    ) -> [String: String] {
        let available = Set(AudioDeviceList.selectable(from: outputs, kind: .output).map(\.uid))
        var plan: [String: String] = [:]

        for bundleID in playing {
            let routed = routes.route(for: bundleID).map(\.uid).flatMap {
                available.contains($0) ? $0 : nil
            }
            guard let target = routed ?? defaultOutputUID else { continue }
            if target != defaultOutputUID || levels.hasCustomLevel(for: bundleID) {
                plan[bundleID] = target
            }
        }
        return plan
    }
}
