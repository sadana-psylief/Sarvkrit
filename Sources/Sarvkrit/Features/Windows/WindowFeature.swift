import AppKit
import CoreGraphics
import Foundation
import os
import SwiftUI

/// Move and resize windows with the keyboard, in the style of Rectangle.
///
/// The tap side does nothing but match a keycode and swallow: matching is one dictionary lookup,
/// and the Accessibility work — which can block on the target app — is dispatched off the callback
/// entirely. That split is what keeps typing fast, and it's why the swallow decision can't wait for
/// the window to be inspected.
final class WindowFeature: EventTapFeature, ObservableObject {
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

    /// Mouse events join the mask only while snap-by-dragging is on. `leftMouseDragged` fires at
    /// pointer frequency for **every** drag on the system, so subscribing to it when the feature
    /// can't use it would be a standing cost for nothing. `AppState.sync()` rebuilds the tap when
    /// the option changes.
    var eventMask: CGEventMask {
        let keys = Sarvkrit.eventMask(.keyDown, .keyUp)
        guard snapSettings.snapByDragging else { return keys }
        return keys | Sarvkrit.eventMask(.leftMouseDown, .leftMouseDragged, .leftMouseUp)
    }

    let shortcuts = WindowShortcutStore()
    let snapSettings = SnapSettings()
    private let manipulator = WindowManipulator()
    private lazy var snapController = MainActor.assumeIsolated {
        SnapAreaController(manipulator: manipulator, settings: snapSettings)
    }

    /// Latest pointer position, written on the tap thread and read on main.
    ///
    /// A drag delivers events faster than the main thread can usefully redraw an overlay, so
    /// instead of dispatching one block per event we keep only the newest point and dispatch again
    /// only once the previous block has run. Coalescing rather than queueing is what keeps a drag
    /// from falling behind the pointer.
    private var pendingPoint: CGPoint?
    private var dispatchInFlight = false

    /// Keys whose keyDown we swallowed, so the matching keyUp is swallowed too. Letting a keyUp
    /// through for a keyDown the app never saw leaves its modifier state confused — the same
    /// discipline `CutPasteFeature` keeps for the keys it rewrites.
    private var swallowedKeyDowns: Set<Int64> = []

    /// While the shortcut recorder is open, the tap stands down completely.
    ///
    /// Without this, recording a combination that is *already bound* — which is most of them, since
    /// the recorder is usually used to change an existing binding — would have the tap swallow the
    /// keystroke and snap a window while the user was trying to type it. Read on the tap thread,
    /// written from main, so it takes the same lock as the rest of the shared state.
    private var recording = false
    private var lock = os_unfair_lock_s()

    var isRecording: Bool {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return recording
        }
        set {
            os_unfair_lock_lock(&lock)
            recording = newValue
            os_unfair_lock_unlock(&lock)
        }
    }

    /// The setting; the *per-screen* decision is made inside the manipulator, since one machine can
    /// have an ultrawide and a laptop attached at once.
    var ultrawideEnabled: Bool {
        get { defaults.bool(forKey: Self.ultrawideKey) }
        set {
            // Guarded setter: republishing an unchanged value is what once pinned a CPU core here,
            // and SwiftUI writes back through two-way bindings as a matter of course.
            guard newValue != ultrawideEnabled else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.ultrawideKey)
        }
    }

    /// How much of an ultrawide `Maximize` fills. Stored as a percentage so the slider is in whole
    /// numbers and the value survives a defaults round trip exactly.
    var ultrawideMaxWidthPercent: Int {
        get {
            let stored = defaults.integer(forKey: Self.ultrawideWidthKey)
            return stored == 0 ? 67 : min(max(stored, 40), 100)
        }
        set {
            let clamped = min(max(newValue, 40), 100)
            guard clamped != ultrawideMaxWidthPercent else { return }
            objectWillChange.send()
            defaults.set(clamped, forKey: Self.ultrawideWidthKey)
        }
    }

    /// True when a display currently attached is wide enough for the mode to do anything.
    ///
    /// Used to *offer* the mode, never to switch it on: a shortcut that quietly means something
    /// different depending on which monitor a window is on would be worse than one that is
    /// occasionally suboptimal.
    var hasUltrawideDisplay: Bool {
        NSScreen.screens.contains { WindowLayout.isUltrawide($0.frame) }
    }

    /// Rebinding goes through here so the tap-side index and the pane stay in step.
    func bind(_ action: WindowAction, to shortcut: WindowShortcut?) {
        guard shortcuts.shortcut(for: action) != shortcut else { return }
        objectWillChange.send()
        shortcuts.bind(action, to: shortcut)
    }

    // Snap settings go through the feature so the pane observes one object. Each is a guarded
    // setter — SwiftUI writes back through two-way bindings as a matter of course, and an
    // unchanged value that still republishes is the bug that once pinned a CPU core here.
    func setSnapByDragging(_ value: Bool) {
        guard value != snapSettings.snapByDragging else { return }
        objectWillChange.send()
        snapSettings.snapByDragging = value
    }

    func setRestoreSizeOnUnsnap(_ value: Bool) {
        guard value != snapSettings.restoreSizeOnUnsnap else { return }
        objectWillChange.send()
        snapSettings.restoreSizeOnUnsnap = value
    }

    func setHapticFeedback(_ value: Bool) {
        guard value != snapSettings.hapticFeedback else { return }
        objectWillChange.send()
        snapSettings.hapticFeedback = value
    }

    func setAnimateFootprint(_ value: Bool) {
        guard value != snapSettings.animateFootprint else { return }
        objectWillChange.send()
        snapSettings.animateFootprint = value
    }

    func setSnapAction(_ action: WindowAction?, for zone: SnapZone) {
        guard action != snapSettings.customAction(for: zone) else { return }
        objectWillChange.send()
        snapSettings.setAction(action, for: zone)
    }

    func resetSnapZones() {
        objectWillChange.send()
        snapSettings.resetZones()
    }

    func resetShortcuts() {
        objectWillChange.send()
        shortcuts.resetToDefaults()
    }

    private let defaults = UserDefaults.standard
    private static let ultrawideKey = "windows.ultrawide"
    private static let ultrawideWidthKey = "windows.ultrawideMaxWidthPercent"

    func activate() {
        MainActor.assumeIsolated {
            snapController.configure(
                ultrawideEnabled: { [weak self] in self?.ultrawideEnabled ?? false },
                maxWidthFraction: { [weak self] in
                    CGFloat(self?.ultrawideMaxWidthPercent ?? 67) / 100
                }
            )
        }
    }

    func deactivate() {
        swallowedKeyDowns.removeAll()
        manipulator.forget()
        // A drag interrupted by the feature being switched off must not leave an overlay on screen.
        DispatchQueue.main.async { [weak self] in self?.snapController.cancel() }
    }

    func handle(event: CGEvent, type: CGEventType) -> EventDecision {
        // Mouse first, and always `.pass`: a drag is never swallowed. Branching on type before
        // reading a keycode keeps mouse events out of the keyboard state entirely.
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            handleMouse(event: event, type: type)
            return .pass
        default:
            break
        }

        // Stand down entirely while a shortcut is being recorded, so the combination being typed
        // reaches the recorder instead of moving a window.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if isRecording {
            // Keys swallowed just before recording began still need their keyUp eaten, or the app
            // they went to is left with a modifier stuck down. Everything else passes untouched.
            return swallowedKeyDowns.remove(keyCode) != nil ? .swallow : .pass
        }

        if type == .keyUp {
            return swallowedKeyDowns.remove(keyCode) != nil ? .swallow : .pass
        }
        guard type == .keyDown else { return .pass }

        // Escape ends a drag without snapping. Passed on regardless — the key belongs to whatever
        // the user is doing, not to us.
        if keyCode == WindowShortcut.escapeKey, type == .keyDown {
            DispatchQueue.main.async { [weak self] in self?.snapController.cancel() }
            return .pass
        }

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
            self.manipulator.perform(
                action,
                ultrawideEnabled: self.ultrawideEnabled,
                maxWidthFraction: CGFloat(self.ultrawideMaxWidthPercent) / 100
            )
        }
        return .swallow
    }

    // MARK: - Dragging

    private func handleMouse(event: CGEvent, type: CGEventType) {
        let location = event.location
        switch type {
        case .leftMouseDown:
            DispatchQueue.main.async { [weak self] in self?.snapController.mouseDown(at: location) }

        case .leftMouseDragged:
            // The coalescing described on `pendingPoint`. At 120Hz a per-event dispatch would
            // queue faster than main could drain it and the footprint would lag the pointer.
            os_unfair_lock_lock(&lock)
            pendingPoint = location
            let shouldDispatch = !dispatchInFlight
            if shouldDispatch { dispatchInFlight = true }
            os_unfair_lock_unlock(&lock)

            guard shouldDispatch else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                os_unfair_lock_lock(&self.lock)
                let point = self.pendingPoint
                self.pendingPoint = nil
                self.dispatchInFlight = false
                os_unfair_lock_unlock(&self.lock)
                if let point { self.snapController.mouseDragged(to: point) }
            }

        case .leftMouseUp:
            DispatchQueue.main.async { [weak self] in self?.snapController.mouseUp() }

        default:
            break
        }
    }

    @MainActor func makeDetailView() -> AnyView? {
        AnyView(WindowDetailView(feature: self))
    }

    /// Nudging and resizing are meant to be held down; snapping to a position is not.
    static let repeatable: Set<WindowAction> = [
        .moveLeft, .moveRight, .moveUp, .moveDown, .makeSmaller, .makeLarger,
    ]
}
