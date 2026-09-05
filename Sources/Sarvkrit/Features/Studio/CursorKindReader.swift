import AppKit
import CryptoKit
import Foundation

/// Working out which pointer is on screen.
///
/// **`NSCursor.currentSystem` hands back an image, not an identifier.** So a known pointer is
/// recognised by hashing its bitmap and matching against the system set, and anything unmatched is
/// stored as a bitmap instead.
///
/// The instinct — "never store the bitmap, always draw vectors" — gives a beautiful pointer in
/// Safari and **an arrow where the brush was** in every Photoshop demo. A design tool is exactly
/// the kind of thing people record, so an unrecognised cursor keeps its picture. It costs a handful
/// of small PNGs: a session uses a dozen distinct pointers at most, and they are deduplicated.
enum CursorKindReader {

    private static let knownHashes: [String: CursorKind] = {
        var table: [String: CursorKind] = [:]
        let pairs: [(NSCursor, CursorKind)] = [
            (.arrow, .arrow), (.iBeam, .iBeam), (.pointingHand, .pointingHand),
            (.openHand, .openHand), (.closedHand, .closedHand), (.crosshair, .crosshair),
            (.resizeLeftRight, .resizeLeftRight), (.resizeUpDown, .resizeUpDown),
            (.operationNotAllowed, .notAllowed), (.contextualMenu, .contextualMenu),
        ]
        for (cursor, kind) in pairs {
            if let hash = fingerprint(of: cursor.image) { table[hash] = kind }
        }
        return table
    }()

    /// The kind on screen right now, or `.custom` when nothing matches.
    static func current() -> CursorKind {
        guard let image = NSCursor.currentSystem?.image,
              let hash = fingerprint(of: image) else { return .arrow }
        return knownHashes[hash] ?? .custom
    }

    /// A stable name for a bitmap, used both to recognise known pointers and to deduplicate the
    /// unknown ones on disk.
    static func fingerprint(of image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return SHA256.hash(data: tiff).map { String(format: "%02x", $0) }.joined()
    }

    /// The bitmap of the current pointer, for storing when it could not be recognised.
    static func currentImage() -> NSImage? { NSCursor.currentSystem?.image }
}

/// Whether the focused element is a password field.
///
/// **`ClipboardPrivacyFilter` is not this check.** That reads pasteboard markers — the
/// `org.nspasteboard.ConcealedType` convention password managers set — which says nothing about
/// where a keystroke was typed. This is the Accessibility question, and it is the one that matters
/// when the app is watching the keyboard.
enum SecureFieldCheck {
    static func isFocusedElementSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused else { return false }

        // Unsafe-looking, and it is the documented shape: the value is an AXUIElement.
        let axElement = unsafeBitCast(element, to: AXUIElement.self)
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axElement, attribute as CFString,
                                                &value) == .success,
                  let role = value as? String else { continue }
            if role == "AXSecureTextField" { return true }
        }
        return false
    }
}

/// Turning a key event into something worth showing on screen.
enum KeyLabel {
    /// Nil for anything not worth drawing — a bare letter while "modifiers only" is chosen, or a
    /// key with no sensible name.
    static func describe(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        let name = named(characters) ?? characters.uppercased()
        return parts + name
    }

    static func isCombination(_ event: NSEvent) -> Bool {
        !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// Spelled out, because a caption reading "⌘ " tells nobody anything.
    private static func named(_ characters: String) -> String? {
        switch characters {
        case " ": return "Space"
        case "\r": return "Return"
        case "\t": return "Tab"
        case "\u{7F}", "\u{8}": return "Delete"
        case "\u{1B}": return "Esc"
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        default: return nil
        }
    }
}
