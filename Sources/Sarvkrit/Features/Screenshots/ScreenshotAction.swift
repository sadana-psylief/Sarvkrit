import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Everything the capture features bind a shortcut to.
///
/// Raw values are persisted, so renaming one silently unbinds the user's shortcut — the same rule
/// `Feature.id` carries.
enum ScreenshotAction: String, CaseIterable, Codable, Identifiable {
    case area
    case window
    case fullscreen
    case allInOne
    case scrolling
    case textRecognition
    case restoreOverlay
    case hideOverlays
    case pinClipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullscreen: return "Capture Fullscreen"
        case .allInOne: return "All-In-One"
        case .scrolling: return "Scrolling Capture"
        case .textRecognition: return "Copy Text from Screen"
        case .restoreOverlay: return "Restore Last Overlay"
        case .hideOverlays: return "Hide Overlays"
        case .pinClipboard: return "Pin Clipboard Image"
        }
    }

    /// A unique id per hotkey, because Carbon identifies them by signature plus id and two sharing
    /// one collide silently — `GlobalHotkey.ID`'s own comment records that failure mode.
    var hotkeyID: UInt32 {
        switch self {
        case .area: return GlobalHotkey.ID.captureArea
        case .window: return GlobalHotkey.ID.captureWindow
        case .fullscreen: return GlobalHotkey.ID.captureFullscreen
        case .allInOne: return GlobalHotkey.ID.captureAllInOne
        case .scrolling: return GlobalHotkey.ID.captureScrolling
        case .textRecognition: return GlobalHotkey.ID.captureText
        case .restoreOverlay: return GlobalHotkey.ID.restoreLastOverlay
        case .hideOverlays: return GlobalHotkey.ID.hideOverlays
        case .pinClipboard: return GlobalHotkey.ID.pinClipboardImage
        }
    }

    /// ⌃⇧ plus a key.
    ///
    /// **Not ⌘⇧3/4/5.** Those belong to the macOS screenshot service, which claims them below
    /// `RegisterEventHotKey`, so binding one either reports `eventHotKeyExistsErr` or succeeds and
    /// never fires. ⌃⌥ is the window-management family plus the Shelf's S; ⌃⌥1–5 is the
    /// clipboard's. ⌃⇧ was free.
    var defaultShortcut: WindowShortcut {
        WindowShortcut(keyCode: Int64(defaultKeyCode), modifiers: [.maskControl, .maskShift])
    }

    private var defaultKeyCode: Int {
        switch self {
        case .area: return kVK_ANSI_A
        case .window: return kVK_ANSI_W
        case .fullscreen: return kVK_ANSI_F
        case .allInOne: return kVK_ANSI_5
        case .scrolling: return kVK_ANSI_S
        case .textRecognition: return kVK_ANSI_T
        case .restoreOverlay: return kVK_ANSI_Z
        case .hideOverlays: return kVK_ANSI_H
        case .pinClipboard: return kVK_ANSI_P
        }
    }

    static var defaults: [ScreenshotAction: WindowShortcut] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultShortcut) })
    }
}
