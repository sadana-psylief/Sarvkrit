import CoreGraphics
import Foundation
import os

/// Which key combination triggers which action.
///
/// Rectangle's defaults out of the box, every one of them rebindable. The lookup is a plain
/// dictionary rebuilt on write rather than a scan, because `match` runs inside the event tap on
/// every keystroke the user types.
final class WindowShortcutStore {
    private let defaultsKey = "windows.shortcuts"
    private let defaults: UserDefaults

    private(set) var bindings: [WindowAction: WindowShortcut] = [:]
    /// Reverse index, so matching is one hash lookup instead of 41 comparisons.
    private var byShortcut: [WindowShortcut: WindowAction] = [:]
    /// The index is read on the **event tap thread** and written from the main thread whenever the
    /// user rebinds something. Swift dictionaries are not safe against that, and the failure would
    /// be a rare crash while typing rather than anything reproducible. Uncontended `os_unfair_lock`
    /// costs tens of nanoseconds, which the keystroke path can afford.
    private var lock = os_unfair_lock_s()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bindings = Self.load(from: defaults, key: defaultsKey) ?? Self.rectangleDefaults
        reindex()
    }

    /// The whole point of the reverse index: this runs on the tap thread for every key pressed
    /// anywhere on the system, so it must be O(1) and allocate nothing.
    func action(keyCode: Int64, flags: CGEventFlags) -> WindowAction? {
        let probe = WindowShortcut(keyCode: keyCode, modifiers: WindowShortcut.modifiers(from: flags))
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return byShortcut[probe]
    }

    func shortcut(for action: WindowAction) -> WindowShortcut? { bindings[action] }

    /// Binding a combination that's already in use takes it from the previous action rather than
    /// leaving two actions on one key, where only one of them could ever fire.
    func bind(_ action: WindowAction, to shortcut: WindowShortcut?) {
        if bindings[action] == shortcut { return }   // guarded setter: never republish a no-op
        if let shortcut, let previous = byShortcut[shortcut], previous != action {
            bindings.removeValue(forKey: previous)
        }
        if let shortcut {
            bindings[action] = shortcut
        } else {
            bindings.removeValue(forKey: action)
        }
        reindex()
        save()
    }

    func resetToDefaults() {
        bindings = Self.rectangleDefaults
        reindex()
        save()
    }

    private func reindex() {
        var rebuilt: [WindowShortcut: WindowAction] = [:]
        for (action, shortcut) in bindings { rebuilt[shortcut] = action }
        os_unfair_lock_lock(&lock)
        byShortcut = rebuilt
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Persistence

    /// Stores the whole map, including bindings identical to the defaults.
    ///
    /// Deliberate, and the opposite of what `SnapSettings` does with its zones: a *cleared*
    /// binding is meaningful here and a missing key cannot express it. Storing only the
    /// differences would make "no shortcut for Maximize" indistinguishable from "Maximize is
    /// unconfigured", and the default would come back the next time the app started.
    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [WindowAction: WindowShortcut]? {
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: WindowShortcut].self, from: data)
        else { return nil }
        // Unknown keys are dropped rather than failing the whole load, so a downgrade after a
        // future release adds actions doesn't wipe every binding the user has.
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            WindowAction(rawValue: key).map { ($0, value) }
        })
    }

    // MARK: - Defaults

    /// Rectangle's shipping defaults, so anyone switching over keeps their muscle memory.
    ///
    /// ⌃⌥ throughout, which is exactly why Clipboard's direct-paste shortcuts are ⌃⌥1–5: digits
    /// and letters don't collide. Actions absent from this table start unbound.
    static let rectangleDefaults: [WindowAction: WindowShortcut] = {
        func key(_ code: Int64, _ mods: CGEventFlags = [.maskControl, .maskAlternate]) -> WindowShortcut {
            WindowShortcut(keyCode: code, modifiers: mods)
        }
        return [
            .leftHalf: key(WindowShortcut.arrowLeft),
            .rightHalf: key(WindowShortcut.arrowRight),
            .topHalf: key(WindowShortcut.arrowUp),
            .bottomHalf: key(WindowShortcut.arrowDown),
            .topLeft: key(32),      // U
            .topRight: key(34),     // I
            .bottomLeft: key(38),   // J
            .bottomRight: key(40),  // K
            .firstThird: key(2),    // D
            .centerThird: key(3),   // F
            .lastThird: key(5),     // G
            .maximize: key(WindowShortcut.returnKey),
            .center: key(8),        // C
            .restore: key(WindowShortcut.deleteKey),
            .makeLarger: key(24),   // =
            .makeSmaller: key(27),  // -
            .nextDisplay: key(WindowShortcut.arrowRight, [.maskControl, .maskAlternate, .maskCommand]),
            .previousDisplay: key(WindowShortcut.arrowLeft, [.maskControl, .maskAlternate, .maskCommand]),
        ]
    }()
}
