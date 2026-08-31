import CoreGraphics
import Foundation

/// Move and resize windows with the keyboard, in the style of Rectangle.
///
/// The tap side does nothing but match a keycode and swallow: matching is one dictionary lookup,
/// and the Accessibility work — which can block on the target app — is dispatched off the callback
/// entirely. That split is what keeps typing fast, and it's why the swallow decision can't wait for
/// the window to be inspected.
final class WindowFeature: EventTapFeature {
    let id = "window-management"
    let category = FeatureCategory.windows
    let title = "Window Management"
    let summary = "Snap windows with the keyboard"
    let details = """
        Move and resize windows without touching the mouse. ⌃⌥ with the arrow keys snaps the \
        focused window to half the screen, U / I / J / K to the corners, D / F / G to thirds, \
        ⌃⌥↩ to maximize and ⌃⌥⌫ to put it back where it was.

        Ultrawide mode retunes the layouts for very wide displays, where a half is wider than \
        anyone wants a window: the arrow keys give thirds instead, and pressing the same one \
        again cycles through a third, a half and two-thirds. It applies per display, so a \
        laptop alongside an ultrawide keeps its halves.
        """
    let symbolName = "macwindow.on.rectangle"
    var shortcutHint: String? { "⌃⌥← / ⌃⌥→" }

    var eventMask: CGEventMask { Sarvkrit.eventMask(.keyDown, .keyUp) }

    let shortcuts = WindowShortcutStore()
    private let manipulator = WindowManipulator()

    /// Keys whose keyDown we swallowed, so the matching keyUp is swallowed too. Letting a keyUp
    /// through for a keyDown the app never saw leaves its modifier state confused — the same
    /// discipline `CutPasteFeature` keeps for the keys it rewrites.
    private var swallowedKeyDowns: Set<Int64> = []

    /// The setting; the *per-screen* decision is made inside the manipulator, since one machine can
    /// have an ultrawide and a laptop attached at once.
    var ultrawideEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "windows.ultrawide") }
        set {
            guard newValue != ultrawideEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: "windows.ultrawide")
        }
    }

    func deactivate() {
        swallowedKeyDowns.removeAll()
        manipulator.forget()
    }

    func handle(event: CGEvent, type: CGEventType) -> EventDecision {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp {
            return swallowedKeyDowns.remove(keyCode) != nil ? .swallow : .pass
        }
        guard type == .keyDown else { return .pass }

        guard let action = shortcuts.action(keyCode: keyCode, flags: event.flags) else { return .pass }

        // Held-down keys arrive as repeats. Swallow them either way — releasing a swallowed key's
        // repeats into the app would type into it — but only *act* on repeats for actions where
        // repeating is the point. Holding ⌃⌥← on an ultrawide would otherwise spin the
        // third → half → two-thirds cycle many times a second.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        swallowedKeyDowns.insert(keyCode)
        guard !isRepeat || WindowFeature.repeatable.contains(action) else { return .swallow }

        // Off the tap thread before touching Accessibility — AX calls block on the target app.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.manipulator.perform(action, ultrawideEnabled: self.ultrawideEnabled)
        }
        return .swallow
    }

    /// Nudging and resizing are meant to be held down; snapping to a position is not.
    static let repeatable: Set<WindowAction> = [
        .moveLeft, .moveRight, .moveUp, .moveDown, .makeSmaller, .makeLarger,
    ]
}
