import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Translating a shortcut's modifiers from the event-tap world to Carbon's.
///
/// **This is a silent-failure trap, which is why it is a named function with tests rather than an
/// inline expression.** `RegisterEventHotKey` takes Carbon masks (`cmdKey`, `shiftKey`,
/// `optionKey`, `controlKey`) whose numeric values are unrelated to `CGEventFlags`. Passing one
/// where the other is expected compiles — both are integers — and registers a *different*
/// combination, with no error and nothing to notice until the shortcut doesn't work and a
/// different one mysteriously does.
///
/// The app has both representations in play: `WindowShortcut` stores `CGEventFlags` because it is
/// matched inside the event tap, while `GlobalHotkey` needs Carbon because it registers with the
/// system. Anything rebindable has to cross the gap.
enum CarbonModifiers {

    static func from(_ flags: CGEventFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.maskCommand)   { carbon |= UInt32(cmdKey) }
        if flags.contains(.maskShift)     { carbon |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        if flags.contains(.maskControl)   { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// The inverse, for showing a registered hotkey in the same UI as a rebindable one.
    static func toEventFlags(_ carbon: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if carbon & UInt32(cmdKey) != 0     { flags.insert(.maskCommand) }
        if carbon & UInt32(shiftKey) != 0   { flags.insert(.maskShift) }
        if carbon & UInt32(optionKey) != 0  { flags.insert(.maskAlternate) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        return flags
    }
}
