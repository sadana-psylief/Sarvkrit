import Carbon.HIToolbox
import Foundation

/// The recording shortcuts.
///
/// Raw values are persisted, so renaming one silently unbinds the user's shortcut — the same rule
/// `Feature.id` and `ScreenshotAction` carry.
enum RecordingAction: String, CaseIterable, Codable, Identifiable {
    case startStop
    case recordArea
    case pauseResume
    case flag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startStop: return "Start or Stop Recording"
        case .recordArea: return "Record an Area"
        case .pauseResume: return "Pause or Resume Recording"
        case .flag: return "Mark This Moment"
        }
    }

    var hotkeyID: UInt32 {
        switch self {
        case .startStop: return GlobalHotkey.ID.recordStartStop
        case .recordArea: return GlobalHotkey.ID.recordArea
        case .pauseResume: return GlobalHotkey.ID.recordPauseResume
        case .flag: return GlobalHotkey.ID.recordFlag
        }
    }

    /// ⌃⇧ plus a key, joining the family Capture already owns rather than claiming a new one.
    /// R, E and U are free: `ScreenshotAction` takes A W F 5 S T Z H P Y, and ⌃⇧⎋ dismisses
    /// everything.
    var defaultShortcut: WindowShortcut {
        WindowShortcut(keyCode: Int64(defaultKeyCode), modifiers: [.maskControl, .maskShift])
    }

    private var defaultKeyCode: Int {
        switch self {
        case .startStop: return kVK_ANSI_R
        case .recordArea: return kVK_ANSI_E
        case .pauseResume: return kVK_ANSI_U
        case .flag: return kVK_ANSI_M
        }
    }

    static var defaults: [RecordingAction: WindowShortcut] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultShortcut) })
    }
}

extension RecordingAction: ShortcutOwner {
    var shortcutTitle: String { title }
}
