import AppKit
import Foundation

/// Which editor action a keystroke means.
///
/// Pure, and separate from the window that installs the monitor, for the same reason
/// `EditorKeyRouting` is: the app has no main menu to hang items on — it is a `MenuBarExtra`
/// accessory — so every shortcut is matched by hand, and a table matched by hand is a table worth
/// testing exhaustively.
enum StudioKeyRouting {

    enum Action: Equatable {
        case playPause
        case stepFrames(Int)
        case stepSeconds(Int)
        /// J/K/L. −1 backwards, 0 stop, 1 forwards; repeated presses double the rate.
        case shuttle(Int)
        case split
        /// Remove the clip and close the gap.
        case rippleDelete
        /// Lift the selection and leave the gap.
        case deleteSelection
        case setIn
        case setOut
        case addZoom
        case setZoomLevel(Int)
        case undo
        case redo
        case save
        case export
        case close
        case fitTimeline
        case loopPlayback
        case copyFrame
        case resetEdits
        case showShortcuts
        case commandMenu
    }

    private static let leftArrow = "\u{F702}"
    private static let rightArrow = "\u{F703}"
    private static let deleteKey = "\u{7F}"
    private static let backspaceKey = "\u{8}"

    /// - Parameter isEditingText: whether a text field has focus — the transcript editor, a caption,
    ///   a project name.
    ///
    ///   **Every bare-key shortcut here is a letter somebody might type.** So while a field has
    ///   focus none of them may fire, or renaming a project splits the timeline. The command-key
    ///   shortcuts keep working, because ⌘Z inside a text field is what everybody expects.
    static func action(forCharacters characters: String,
                       modifiers: NSEvent.ModifierFlags,
                       isEditingText: Bool) -> Action? {
        let key = characters.lowercased()
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        if command {
            switch key {
            case "z": return shift ? .redo : .undo
            case "b": return .split
            case "s": return .save
            case "e": return .export
            case "w": return .close
            case "k": return .commandMenu
            case "c": return .copyFrame
            case "l": return .loopPlayback
            case "0": return .fitTimeline
            case "/": return .showShortcuts
            case deleteKey, backspaceKey: return .resetEdits
            default: return nil
            }
        }

        guard !isEditingText else { return nil }

        switch key {
        case " ": return .playPause
        case leftArrow: return shift ? .stepSeconds(-1) : .stepFrames(-1)
        case rightArrow: return shift ? .stepSeconds(1) : .stepFrames(1)
        case ",": return .stepFrames(-1)
        case ".": return .stepFrames(1)
        case "l": return .shuttle(1)
        case "j": return .shuttle(-1)
        case "k": return .shuttle(0)
        case "x": return .rippleDelete
        case deleteKey, backspaceKey: return .deleteSelection
        case "i": return .setIn
        case "o": return .setOut
        case "z": return .addZoom
        default:
            // Digits set the selected zoom's level, which is the most repeated action in this
            // window and the one a slider is slowest at.
            if let digit = Int(key), key.count == 1 { return .setZoomLevel(digit) }
            return nil
        }
    }
}
