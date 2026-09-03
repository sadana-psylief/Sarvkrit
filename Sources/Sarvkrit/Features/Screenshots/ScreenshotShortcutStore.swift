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

    @Published private(set) var bindings: [ScreenshotAction: WindowShortcut]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.load(from: defaults, key: defaultsKey) ?? ScreenshotAction.defaults
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
        } else {
            bindings.removeValue(forKey: action)
        }
        save()
    }

    func resetToDefaults() {
        bindings = ScreenshotAction.defaults
        save()
    }

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
        } catch {
            log.error("couldn't save capture shortcuts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults,
                             key: String) -> [ScreenshotAction: WindowShortcut]? {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: WindowShortcut].self, from: data)
        else { return nil }
        // An action that no longer exists is dropped rather than failing the whole decode —
        // otherwise removing one mode in a later version resets every binding the user made.
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            ScreenshotAction(rawValue: key).map { ($0, value) }
        })
    }
}
