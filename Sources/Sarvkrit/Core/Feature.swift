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
    case capture
    case files
    case sound
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .clipboard: return "Clipboard"
        case .windows: return "Windows"
        case .capture: return "Capture"
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
        case .capture: return "camera.viewfinder"
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
    /// Reading what is on the display. Queryable like Accessibility, but with one difference that
    /// shapes the whole UI around it: **macOS does not hand a new grant to a running process.**
    /// Accessibility flips live and `AppState.sync()` retries activation, so granting it works
    /// without a relaunch. Screen Recording does not — `CGRequestScreenCaptureAccess()` returns
    /// false, adds the app to the list, and this process keeps getting denied results until it is
    /// restarted. Denial isn't an error either: ScreenCaptureKit simply reports no displays. See
    /// `ScreenRecordingRelaunch`.
    case screenRecording

    var title: String {
        switch self {
        case .accessibility: return "Accessibility access"
        case .audioCapture: return "System audio recording"
        case .screenRecording: return "Screen Recording access"
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
        case .screenRecording:
            return "Taking a screenshot means reading what's on your display, which macOS classes "
                 + "as recording the screen."
        }
    }

    /// Whether the app can tell for itself if this has been granted.
    ///
    /// False for audio: there is no query, so the only evidence is silence where sound should be.
    var isQueryable: Bool {
        switch self {
        case .accessibility, .screenRecording: return true
        case .audioCapture: return false
        }
    }

    /// Whether macOS offers a way to *ask* for this, as opposed to only a settings pane to send
    /// the user to.
    ///
    /// **This is what makes the grant reachable at all for Screen Recording.** An app does not
    /// appear in that settings list until it has asked once — so "Open Settings" alone sends the
    /// user to a list Sarvkrit is not in, with nothing to switch on. Asking first is what puts it
    /// there. Audio capture has no request API, which is the whole reason it is handled by
    /// noticing silence instead.
    var isRequestable: Bool {
        switch self {
        case .accessibility, .screenRecording: return true
        case .audioCapture: return false
        }
    }

    /// Declaration order, so a `Set<Requirement>` can be rendered in a stable order.
    ///
    /// `AppState.unmetRequirements` is a `Set`, and a `Set`'s iteration order is not stable between
    /// launches — without this, two missing grants would swap places in the dropdown at random.
    var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .audioCapture:
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        case .screenRecording:
            return URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
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

    /// The panels this feature puts in the menu bar, in strip order.
    ///
    /// This replaced `makeTrayView()`, which could only append content *underneath* the feature's
    /// own switch. That was right while the panel was a switchboard and wrong once a feature had
    /// something worth leading with: the volume mixer and the system monitor were the two things
    /// people opened the menu for, and both were reachable only by first finding the switch that
    /// turned them on.
    ///
    /// A feature may return several — the system monitor returns System, Network, Disks and Power,
    /// because a 420pt window holds one card comfortably and four badly — or share one id with
    /// other features, which `TrayPanel.merged(_:)` collapses into a single tab. Returning `[]`,
    /// the default, means the feature appears only as a switch in the Features tab.
    ///
    /// Only called for features that are switched on and not blocked, so an implementation never
    /// has to check either — unless `panelIsItsOwnSwitch` says otherwise.
    @MainActor func trayPanels() -> [TrayPanel]

    /// Whether this feature's panel should be shown even while the feature is switched off.
    ///
    /// False for almost everything: a mixer with no tap running, or a monitor with no samples, has
    /// nothing to draw, and its panel would be an empty card inviting you to go elsewhere.
    ///
    /// True for Keep Awake alone, where switching the feature on *is* the thing the panel offers.
    /// Hiding it while off would put "keep my Mac awake" behind a detour through Features — the
    /// switch being the control is exactly why it must stay reachable.
    var panelIsItsOwnSwitch: Bool { get }
}

extension Feature {
    var shortcutHint: String? { nil }
    var requirements: Set<Requirement> { [.accessibility] }
    func activate() {}
    func deactivate() {}
    @MainActor func makeDetailView() -> AnyView? { nil }
    @MainActor func trayPanels() -> [TrayPanel] { [] }
    var panelIsItsOwnSwitch: Bool { false }

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
