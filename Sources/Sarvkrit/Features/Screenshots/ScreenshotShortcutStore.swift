import CoreGraphics
import Foundation
import os

/// Which combination triggers which capture.
///
/// Modelled on `WindowShortcutStore`, with one difference that follows from the mechanism: these
/// are registered with Carbon rather than matched in the event tap, so there is no tap-thread read
/// and therefore no lock. Rebinding re-registers instead of updating a reverse index.
///
/// **The whole map is persisted, not just the changed entries.** A binding the user *cleared* has
/// to be expressible, and it isn't if an absent key means "use the default" — the same reasoning
/// `WindowShortcutStore` records.
final class ScreenshotShortcutStore: ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")
    private let defaultsKey = "screenshot.shortcuts"
    private let defaults: UserDefaults

    private let clearedKey = "screenshot.clearedShortcuts"

    @Published private(set) var bindings: [ScreenshotAction: WindowShortcut]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.load(from: defaults, bindingsKey: defaultsKey, clearedKey: clearedKey)
        self.cleared = Set((defaults.array(forKey: clearedKey) as? [String] ?? [])
            .compactMap(ScreenshotAction.init(rawValue:)))
    }

    func shortcut(for action: ScreenshotAction) -> WindowShortcut? { bindings[action] }

    /// Binding a combination already in use takes it from the previous action rather than leaving
    /// two on one key, where only one could ever fire.
    func bind(_ action: ScreenshotAction, to shortcut: WindowShortcut?) {
        if bindings[action] == shortcut { return }
        if let shortcut,
           let previous = bindings.first(where: { $0.value == shortcut && $0.key != action })?.key {
            bindings.removeValue(forKey: previous)
        }
        if let shortcut {
            bindings[action] = shortcut
            cleared.remove(action)
        } else {
            bindings.removeValue(forKey: action)
            cleared.insert(action)
        }
        save()
    }

    func resetToDefaults() {
        bindings = ScreenshotAction.defaults
        cleared = []
        save()
    }

    /// Bindings the user deliberately removed.
    ///
    /// **Recorded separately from the map, and this is not bookkeeping for its own sake.** Before,
    /// an action simply absent from the stored map meant "cleared" — which made a *newly added*
    /// action indistinguishable from a cleared one, so any shortcut introduced in a later version
    /// would silently never register for anyone who had ever changed a binding. Defaults now fill
    /// in for anything unknown, and only this set suppresses them.
    private var cleared: Set<ScreenshotAction> = []

    /// Which capture a combination triggers, for the window recorder's conflict warning.
    static func match(keyCode: Int64, flags: CGEventFlags,
                      in bindings: [ScreenshotAction: WindowShortcut]) -> ScreenshotAction? {
        bindings.first { $0.value.matches(keyCode: keyCode, flags: flags) }?.key
    }

    // MARK: - Persistence

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues:
            bindings.map { ($0.key.rawValue, $0.value) })
        do {
            defaults.set(try JSONEncoder().encode(encodable), forKey: defaultsKey)
            defaults.set(cleared.map(\.rawValue).sorted(), forKey: clearedKey)
        } catch {
            log.error("couldn't save capture shortcuts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults,
                             bindingsKey: String,
                             clearedKey: String) -> [ScreenshotAction: WindowShortcut] {
        var result = ScreenshotAction.defaults

        // Anything the user explicitly cleared stays cleared.
        let cleared = Set((defaults.array(forKey: clearedKey) as? [String] ?? [])
            .compactMap(ScreenshotAction.init(rawValue:)))
        for action in cleared { result.removeValue(forKey: action) }

        guard let data = defaults.data(forKey: bindingsKey),
              let raw = try? JSONDecoder().decode([String: WindowShortcut].self, from: data)
        else { return result }

        // An action that no longer exists is dropped rather than failing the whole decode —
        // otherwise removing one mode in a later version resets every binding the user made.
        for (key, shortcut) in raw {
            guard let action = ScreenshotAction(rawValue: key) else { continue }
            result[action] = shortcut
        }
        // A rebind can move a combination onto an action that already had one; make sure two
        // actions never end up sharing a key after a merge.
        var seen: [WindowShortcut: ScreenshotAction] = [:]
        for (action, shortcut) in result.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let owner = seen[shortcut], owner != action {
                result.removeValue(forKey: action)
            } else {
                seen[shortcut] = action
            }
        }
        return result
    }
}
