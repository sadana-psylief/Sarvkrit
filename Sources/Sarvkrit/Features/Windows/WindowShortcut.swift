import CoreGraphics
import Foundation

/// One key combination, stored as the keycode and the modifiers that must be held exactly.
///
/// Keycode rather than character on purpose: it survives a keyboard-layout change, so a binding
/// made on QWERTY still lands on the same physical key on Dvorak.
struct WindowShortcut: Codable, Hashable {
    var keyCode: Int64
    /// Raw value of the `CGEventFlags` subset we care about, so this stays `Codable`.
    var modifiers: UInt64

    init(keyCode: Int64, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    /// The modifiers a shortcut is allowed to specify. Anything else — caps lock, the numeric
    /// keypad bit, the left/right device flags — is noise that varies between keyboards and would
    /// stop a binding from ever matching.
    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    static func modifiers(from flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(relevantModifiers)
    }

    /// Exact match, never a subset: ⌃⌥← must not fire on ⌃⌥⇧←, which belongs to someone else.
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && self.flags == WindowShortcut.modifiers(from: flags)
    }

    /// ⌃⌥← and similar, for display in the settings pane and the tray.
    var displayString: String {
        var result = ""
        let f = flags
        if f.contains(.maskControl) { result += "⌃" }
        if f.contains(.maskAlternate) { result += "⌥" }
        if f.contains(.maskShift) { result += "⇧" }
        if f.contains(.maskCommand) { result += "⌘" }
        return result + WindowShortcut.keyName(keyCode)
    }

    static func keyName(_ keyCode: Int64) -> String {
        if let named = namedKeys[keyCode] { return named }
        return letterKeys[keyCode].map(String.init) ?? "Key \(keyCode)"
    }

    // ANSI virtual key codes.
    static let arrowLeft: Int64 = 123
    static let arrowRight: Int64 = 124
    static let arrowDown: Int64 = 125
    static let arrowUp: Int64 = 126
    static let returnKey: Int64 = 36
    static let deleteKey: Int64 = 51
    static let escapeKey: Int64 = 53
    static let tabKey: Int64 = 48
    static let spaceKey: Int64 = 49

    private static let namedKeys: [Int64: String] = [
        arrowLeft: "←", arrowRight: "→", arrowDown: "↓", arrowUp: "↑",
        returnKey: "↩", deleteKey: "⌫", escapeKey: "⎋", tabKey: "⇥", spaceKey: "Space",
    ]

    private static let letterKeys: [Int64: Character] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
    ]
}
