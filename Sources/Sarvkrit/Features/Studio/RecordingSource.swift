import Foundation

/// What a recording is a recording *of*.
///
/// **Deliberately not a case on `CaptureMode`.** That enum's raw values are persisted in the
/// screenshot history index and it drives four exhaustive switches plus the history shelf's mode
/// filter; a recording is not a screenshot mode and pretending otherwise would put video concepts
/// into every one of those. Raw values here are persisted in the recording bundle, so they are
/// equally permanent.
enum RecordingSource: String, Codable, CaseIterable, Equatable, Identifiable {
    case display
    case window
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: return "Display"
        case .window: return "Window"
        case .area: return "Area"
        }
    }

    var symbolName: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        case .area: return "selection.pin.in.out"
        }
    }

    /// Whether the frozen-screen overlay is used to aim this. The other two are chosen by pointing
    /// at something that already has edges, so there is nothing to drag.
    var aimsByDragging: Bool {
        switch self {
        case .area: return true
        case .display, .window: return false
        }
    }
}
