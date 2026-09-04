import Foundation

/// How a given display's brightness can be changed, if at all.
///
/// Three mechanisms, none of them universal, and which one applies depends on the display rather
/// than on the Mac. Choosing between them is a pure decision so that it is a test table rather than
/// something reproducible only with a particular monitor plugged in — the situation that makes
/// display code hard to work on.
enum BrightnessChannel: Equatable {
    /// `DisplayServices`. The built-in panel, and some Apple externals. Real brightness, and the
    /// only channel that can raise it as well as lower it on those displays.
    case displayServices
    /// DDC/CI over `IOAVService`. The standard for third-party monitors, spoken over the video
    /// cable itself, so it moves the monitor's own backlight exactly as its buttons would.
    case ddc
    /// Gamma tables. Not brightness at all: it darkens the *picture* the Mac sends. Works on any
    /// display, and cannot make one brighter than its own setting, which is why it is last.
    case gamma
    /// Nothing worked. The panel shows the display and says so rather than offering a slider that
    /// does nothing.
    case unavailable

    /// What a display can actually do, established once by probing.
    struct Capabilities: Equatable {
        var isBuiltIn: Bool
        var respondsToDisplayServices: Bool
        var respondsToDDC: Bool
        /// Gamma is available for any display the Mac is driving, so this is false only where the
        /// display has gone away between probing and asking.
        var supportsGamma: Bool = true
    }

    /// Real brightness before apparent brightness, always.
    ///
    /// The order is not preference, it is honesty: `displayServices` and `ddc` move the backlight,
    /// so 50% looks like 50% and the display's own controls agree with Sarvkrit. Gamma only dims
    /// the signal — the backlight stays where it was, black stops being black, and the display's
    /// own menu still says 100%. It is a real fallback and a poor substitute, so it is used only
    /// when neither real channel answers.
    static func choose(_ capabilities: Capabilities) -> BrightnessChannel {
        if capabilities.respondsToDisplayServices { return .displayServices }
        // Never for the built-in panel: it has no DDC, and probing it wastes an I²C round trip on
        // every display refresh.
        if !capabilities.isBuiltIn, capabilities.respondsToDDC { return .ddc }
        if capabilities.supportsGamma { return .gamma }
        return .unavailable
    }

    /// Whether this channel can make a display brighter than the state the Mac found it in.
    ///
    /// The one thing the UI must not get wrong. A gamma slider that starts at 100% and only goes
    /// down is honest; one that pretends the top half does something is not.
    var canIncreaseBeyondCurrent: Bool {
        switch self {
        case .displayServices, .ddc: return true
        case .gamma, .unavailable: return false
        }
    }

    var explanation: String? {
        switch self {
        case .displayServices, .ddc: return nil
        case .gamma: return "Dims the picture — this display has no brightness control macOS can reach"
        case .unavailable: return "Brightness can't be changed on this display"
        }
    }
}
