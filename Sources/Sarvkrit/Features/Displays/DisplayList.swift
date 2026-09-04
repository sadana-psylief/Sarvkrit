import AppKit
import CoreGraphics

/// One display the Mac is currently driving.
struct ConnectedDisplay: Equatable, Identifiable {
    var id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
}

/// Which displays are connected, and what they are called.
///
/// `CGGetOnlineDisplayList` gives the IDs; only `NSScreen` knows the names, and it does not expose
/// the ID directly — it comes back in the device description under a key that has no constant. The
/// two are matched on that rather than on index, because the orders are unrelated.
enum DisplayList {
    static func current() -> [ConnectedDisplay] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        let names = screenNames()
        return ids.compactMap { id in
            // A mirrored display is driven by another one and has no brightness of its own; the
            // primary is already in the list.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            return ConnectedDisplay(
                id: id,
                name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : "Display"),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return names
    }
}
