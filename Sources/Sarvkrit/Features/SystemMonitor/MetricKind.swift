import Foundation

/// The seven things the monitor can watch, each independently switchable.
///
/// Raw values are persisted in `systemMonitor.enabledMetrics` and `systemMonitor.menuBarMetrics`,
/// so renaming one silently resets the user's choice — the same contract `Feature.id` carries.
/// Declaration order is the order the pane lists them in.
enum MetricKind: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case power
    case battery
    case memory
    case disk
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .power: return "Power"
        case .battery: return "Battery"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        }
    }

    /// The short code used in the menu bar.
    ///
    /// Text, not an SF Symbol, and not by preference: a `MenuBarExtra` label renders exactly one
    /// `Image` and one `Text` and silently drops everything else — inline images inside a
    /// concatenated `Text` included — so a per-segment icon cannot appear there at all. Three
    /// letters is what makes a bare "66% · 12%" say which number is which.
    var menuBarLabel: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .power: return "PWR"
        case .battery: return "BAT"
        case .memory: return "MEM"
        case .disk: return "DSK"
        case .network: return "NET"
        }
    }

    /// Template SF Symbols throughout: a coloured glyph would opt out of inverting on light and
    /// dark menu bars and of dimming when the menu bar is inactive.
    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .power: return "bolt"
        case .battery: return "battery.100"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "arrow.down.circle"
        }
    }
}
