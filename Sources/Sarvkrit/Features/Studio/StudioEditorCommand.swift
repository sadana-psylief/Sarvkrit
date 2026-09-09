import Foundation

/// An editor action, addressable by name.
///
/// **So the editor's edits can be driven without a mouse.** Every round of this feature's bugs has
/// been reported against something behind a click — the Play button, the scrubber, the Export panel
/// — and none could be reproduced here, because this machine refuses synthetic input. Naming the
/// actions makes them scriptable, which is also what somebody binding "split at the playhead" to a
/// Stream Deck key wants.
///
/// Deliberately a small, flat list rather than a mirror of `StudioKeyRouting.Action`: the actions
/// with associated values (a shuttle direction, a zoom level) do not belong in a URL.
enum StudioEditorCommand: String, CaseIterable, Equatable {
    case split
    case duplicateClip = "duplicate-clip"
    case deleteSelection = "delete"
    case addZoom = "add-zoom"
    case addText = "add-text"
    case addClick = "add-click"
    case addPointerHighlight = "add-pointer-highlight"
    case addMask = "add-mask"
    /// Closes the editor, exactly as ⌘W does — including the autosave and the notice that says
    /// the recording was kept. So "export it and put it away" is one script.
    case close
    case undo
    case redo
    case resetEdits = "reset"
}
