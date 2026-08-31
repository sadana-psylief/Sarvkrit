import Foundation

/// Snap-area preferences: the four options and the nine zone assignments.
///
/// Read only from the main thread — the drag session runs there — so unlike `WindowShortcutStore`
/// this needs no lock.
final class SnapSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        zoneActions = Self.loadZones(from: defaults) ?? [:]
    }

    /// Whether dragging to an edge does anything at all. Off by default: it changes what an
    /// ordinary window drag does, which is not something to switch on behind someone's back.
    var snapByDragging: Bool {
        get { defaults.bool(forKey: "windows.snapByDragging") }
        set {
            guard newValue != snapByDragging else { return }
            defaults.set(newValue, forKey: "windows.snapByDragging")
        }
    }

    /// Dragging a snapped window away from its edge gives it back the size it had before.
    var restoreSizeOnUnsnap: Bool {
        get { defaults.object(forKey: "windows.restoreOnUnsnap") as? Bool ?? true }
        set {
            guard newValue != restoreSizeOnUnsnap else { return }
            defaults.set(newValue, forKey: "windows.restoreOnUnsnap")
        }
    }

    /// Trackpads only — `NSHapticFeedbackManager` is silently inert on a mouse.
    var hapticFeedback: Bool {
        get { defaults.object(forKey: "windows.snapHaptics") as? Bool ?? true }
        set {
            guard newValue != hapticFeedback else { return }
            defaults.set(newValue, forKey: "windows.snapHaptics")
        }
    }

    var animateFootprint: Bool {
        get { defaults.object(forKey: "windows.animateFootprint") as? Bool ?? true }
        set {
            guard newValue != animateFootprint else { return }
            defaults.set(newValue, forKey: "windows.animateFootprint")
        }
    }

    /// Only zones the user has actually changed are stored, so the ultrawide defaults keep applying
    /// to the rest — a stored copy of every default would freeze them at whatever they were when
    /// the pane was first opened.
    private var zoneActions: [SnapZone: WindowAction]

    func action(for zone: SnapZone, ultrawide: Bool) -> WindowAction {
        zoneActions[zone] ?? SnapZoneLayout.defaultAction(for: zone, ultrawide: ultrawide)
    }

    /// The user's explicit choice, or nil where the default still applies.
    func customAction(for zone: SnapZone) -> WindowAction? { zoneActions[zone] }

    func setAction(_ action: WindowAction?, for zone: SnapZone) {
        guard zoneActions[zone] != action else { return }
        if let action { zoneActions[zone] = action } else { zoneActions.removeValue(forKey: zone) }
        saveZones()
    }

    func resetZones() {
        guard !zoneActions.isEmpty else { return }
        zoneActions = [:]
        saveZones()
    }

    private func saveZones() {
        let raw = Dictionary(uniqueKeysWithValues: zoneActions.map { ($0.key.rawValue, $0.value.rawValue) })
        defaults.set(raw, forKey: Self.zonesKey)
    }

    private static let zonesKey = "windows.snapZones"

    private static func loadZones(from defaults: UserDefaults) -> [SnapZone: WindowAction]? {
        guard let raw = defaults.dictionary(forKey: zonesKey) as? [String: String] else { return nil }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            guard let zone = SnapZone(rawValue: key), let action = WindowAction(rawValue: value)
            else { return nil }   // drop unknown entries rather than failing the whole load
            return (zone, action)
        })
    }
}
