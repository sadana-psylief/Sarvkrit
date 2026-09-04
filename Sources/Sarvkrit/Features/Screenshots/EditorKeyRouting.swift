import AppKit
import Foundation

/// Which tool a key selects.
enum ToolKind: String, CaseIterable, Identifiable, Equatable {
    case select
    case crop
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case highlighter
    case pencil
    case counter
    case blur
    case pixelate
    case spotlight
    case emoji

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .crop: return "Crop"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .pencil: return "Pencil"
        case .counter: return "Counter"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .spotlight: return "Spotlight"
        case .emoji: return "Emoji"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .pencil: return "pencil"
        case .counter: return "1.circle"
        case .blur: return "drop.fill"
        case .pixelate: return "square.grid.3x3.fill"
        case .spotlight: return "sun.max"
        case .emoji: return "face.smiling"
        }
    }

    /// The single-key shortcut. Matches CleanShot's, which is muscle memory worth not breaking.
    var key: String? {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .text: return "t"
        case .highlighter: return "h"
        case .pencil: return "d"
        case .counter: return "n"
        case .blur: return "b"
        case .pixelate: return "p"
        case .spotlight: return "s"
        case .emoji: return ";"
        }
    }
}

/// What a keystroke means inside the editor.
///
/// Pure, so the whole shortcut table is a test rather than something checked by opening a window
/// and pressing keys.
enum EditorKeyRouting {

    enum Action: Equatable {
        case selectTool(ToolKind)
        case selectColour(Int)
        case undo, redo
        case copy, save, saveEditable, close
        case selectAll, duplicate, deleteSelection
        case cancel
    }

    /// - Parameter isEditingText: **the reason this function has a third argument.** While a text
    ///   annotation is being typed into, the letters belong to the text — routing "r" to the
    ///   rectangle tool mid-word is the single most likely bug in this area, and it is invisible
    ///   until someone types a word containing a tool letter.
    static func action(forCharacters characters: String,
                       modifiers: NSEvent.ModifierFlags,
                       isEditingText: Bool) -> Action? {
        let key = characters.lowercased()
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        if command {
            switch key {
            case "z": return shift ? .redo : .undo
            case "c": return .copy
            case "s": return shift ? .saveEditable : .save
            case "w": return .close
            case "a": return .selectAll
            case "d": return .duplicate
            default: return nil
            }
        }

        // Escape always works: it is how a half-drawn element or a text edit is abandoned, and a
        // text field that swallowed it would leave the user with no way out but the mouse.
        if key == "\u{1b}" { return .cancel }

        guard !isEditingText else { return nil }

        switch key {
        case "\u{7f}", "\u{8}", "\u{f728}": return .deleteSelection
        default: break
        }

        if let digit = Int(key), (1...6).contains(digit) { return .selectColour(digit) }
        if let tool = ToolKind.allCases.first(where: { $0.key == key }) {
            return .selectTool(tool)
        }
        return nil
    }
}
