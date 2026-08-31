import CoreGraphics
import Foundation
import SwiftUI

/// What the event tap should do with an event after a feature has looked at it.
///
/// Features mutate `CGEvent`s in place (it's a reference type), so `.pass` covers both
/// "untouched" and "rewritten". `.swallow` is here for features that need to consume a
/// key outright; none of the shipping features do.
enum EventDecision {
    case pass
    case swallow
}

/// How features are grouped in the tray and the sidebar. Raw values are stable — they'd be
/// persisted if grouping ever became collapsible — and declaration order is display order.
enum FeatureCategory: String, CaseIterable, Identifiable {
    case keyboard
    case clipboard
    case windows
    case files
    case sound
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .clipboard: return "Clipboard"
        case .windows: return "Windows"
        case .files: return "Files"
        case .sound: return "Sound"
        case .system: return "System"
        }
    }

    var symbolName: String {
        switch self {
        case .keyboard: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .windows: return "macwindow"
        case .files: return "folder"
        case .sound: return "speaker.wave.2"
        case .system: return "gearshape.2"
        }
    }
}

/// A permission a feature can't work without.
///
/// Replaces the old `requiresAccessibility: Bool`, which couldn't express anything else. File
/// features need folder access, which is a different grant with different UI, so the app has to be
/// able to talk about more than one kind.
enum Requirement: Hashable, CaseIterable {
    case accessibility
    /// Recording what other apps are playing. Its own TCC category, separate from the microphone.
    ///
    /// Unlike Accessibility there is **no API to request it or to ask whether it was granted**, and
    /// denial is silent — Core Audio returns success and hands back empty buffers. So a feature
    /// needing this can't be gated up front the way the tap features are; it has to notice
    /// afterwards that it heard nothing. See `VolumeMixerFeature`.
    case audioCapture

    var title: String {
        switch self {
        case .accessibility: return "Accessibility access"
        case .audioCapture: return "System audio recording"
        }
    }

    /// Why the app wants it, in the user's terms.
    var explanation: String {
        switch self {
        case .accessibility:
            return "Sarvkrit can't watch for keys or clicks until you allow it in System Settings."
        case .audioCapture:
            return "Setting an app's volume means routing its audio through Sarvkrit, which macOS "
                 + "treats as recording it."
        }
    }

    /// Whether the app can tell for itself if this has been granted.
    ///
    /// False for audio: there is no query, so the only evidence is silence where sound should be.
    var isQueryable: Bool { self == .accessibility }

    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .audioCapture:
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        }
    }
}

/// One toggleable system tweak — the contract the UI renders from.
///
/// Deliberately says nothing about *how* a feature does its job. Keystroke features consume the
/// shared event tap via `EventTapFeature`; a folder-watching feature has no events at all and
/// conforms to this alone.
///
/// Adding a feature is one file under `Features/` plus one line in `FeatureRegistry`. The tray, the
/// sidebar, the detail pane, persistence and permission gating all follow with no further edits.
protocol Feature: AnyObject {
    /// Stable across releases: this is the UserDefaults key. Renaming it silently resets the
    /// user's choice.
    var id: String { get }
    var category: FeatureCategory { get }
    var title: String { get }
    /// One line, shown under the title in the tray. Keep it under ~45 characters.
    var summary: String { get }
    /// A paragraph, shown in the detail window.
    var details: String { get }
    /// SF Symbol, used in the tray, the sidebar and the detail header alike.
    var symbolName: String { get }
    /// Optional "try it" line in the detail pane, e.g. "⌘X then ⌘V".
    var shortcutHint: String? { get }
    var requirements: Set<Requirement> { get }

    func activate()
    func deactivate()

    /// A feature's own detail pane, when the generic one can't express it.
    ///
    /// `FeatureDetailView` renders title / toggle / prose / permission status for any feature, which
    /// is all most of them need. A rules editor is not expressible in that shape, so features may
    /// substitute their own. Returning nil — the default — keeps the generic pane.
    @MainActor func makeDetailView() -> AnyView?

    /// Extra content for the tray, shown under the feature's row while it is switched on.
    ///
    /// The tray is otherwise strictly one toggle row per feature, which is right for a feature you
    /// turn on and forget. It is wrong for one you *operate* from the tray — picking an output
    /// device, moving a volume slider — where the row is a switch for something you then need to
    /// use. Returning nil, the default, keeps the plain row.
    @MainActor func makeTrayView() -> AnyView?
}

extension Feature {
    var shortcutHint: String? { nil }
    var requirements: Set<Requirement> { [.accessibility] }
    func activate() {}
    func deactivate() {}
    @MainActor func makeDetailView() -> AnyView? { nil }
    @MainActor func makeTrayView() -> AnyView? { nil }

    var requiresAccessibility: Bool { requirements.contains(.accessibility) }
}

/// A feature that reads or rewrites input events through the one shared `CGEventTap`.
protocol EventTapFeature: Feature {
    /// Which events this feature wants to see. The tap's mask is the union over all enabled
    /// event-tap features.
    var eventMask: CGEventMask { get }
    func handle(event: CGEvent, type: CGEventType) -> EventDecision
}

/// Convenience for building an event mask from `CGEventType`s.
func eventMask(_ types: CGEventType...) -> CGEventMask {
    types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
}
