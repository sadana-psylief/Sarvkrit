import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Owns everything a drag-to-snap needs that isn't pure: the overlay, the AX hit-test, the haptics.
///
/// Lives entirely on the main thread. The tap hands it points and nothing else — see
/// `WindowFeature` for the budget that path has to keep.
@MainActor
final class SnapAreaController {
    private var session = SnapDragSession()
    private let footprint = FootprintPanel()
    private let manipulator: WindowManipulator
    private let settings: SnapSettings

    /// The window the drag started on, captured once at mouse-down while it is still answering.
    private var draggedWindow: AXUIElement?
    /// Its frame, in Cocoa space, read **once** when the drag was armed.
    ///
    /// Re-reading it per pointer move is what made the preview lag: each read is IPC to an app
    /// that is busy redrawing itself mid-drag. A drag moves a window without resizing it, so the
    /// size stays valid throughout, and the position only matters for actions that the drop
    /// applies from the precomputed rect anyway.
    private var draggedFrame: CGRect?
    /// Whether the window was still sitting where we last snapped it when the drag began, decided
    /// once. "Restore size when unsnapped" can only fire once per drag, so asking repeatedly was
    /// pure cost.
    private var wasSnapped = false
    /// The rect the footprint is currently promising, so the drop applies exactly what was shown.
    private var previewedZone: SnapZone?
    /// The screen the pointer is over, resolved once per move and used for the zone, the ultrawide
    /// decision and the target rect alike. Letting those disagree is what puts a footprint on one
    /// display and the window on another.
    private var activeScreen: NSScreen?
    /// Every zone's target rect for `activeScreen`, computed once when the drag reaches that
    /// screen. Moving between zones is then a dictionary lookup rather than arithmetic plus two
    /// blocking Accessibility reads.
    private var zoneRects: [SnapZone: CGRect] = [:]
    private var zoneRectsScreen: CGRect?

    private var ultrawideEnabled: () -> Bool = { false }
    private var maxWidthFraction: () -> CGFloat = { 2.0 / 3.0 }

    init(manipulator: WindowManipulator, settings: SnapSettings) {
        self.manipulator = manipulator
        self.settings = settings
    }

    func configure(ultrawideEnabled: @escaping () -> Bool, maxWidthFraction: @escaping () -> CGFloat) {
        self.ultrawideEnabled = ultrawideEnabled
        self.maxWidthFraction = maxWidthFraction
    }

    // MARK: - Events, all in Accessibility (top-left origin) space

    /// The AX hit-test runs here, off the main thread.
    ///
    /// It costs up to four AX round trips, each capped at 0.25s against an app that may be busy,
    /// and it happens on **every left click anywhere on the system** while snapping is on. On main
    /// that is a visible stutter in whatever the user is clicking. Quit on Close keeps a dedicated
    /// serial queue for the identical hit-test; this mirrors it.
    private let hitTestQueue = DispatchQueue(label: "\(AppIdentity.bundleID).snap-hit-test")

    nonisolated func mouseDown(at point: CGPoint) {
        hitTestQueue.async { [weak self] in
            guard let self else { return }
            // Hit-test while the titlebar is still under the pointer and the app is answering.
            // Waiting for the drag to start races the window moving out from under the point.
            guard let window = self.titlebarWindow(at: point) else { return }
            // Read the frame here too, on the same background hop, so the drag path never has to
            // ask the app anything again. Both are IPC; neither belongs on main.
            let axFrame = WindowManipulator.accessibilityFrame(of: window)
            Task { @MainActor in self.armDrag(window: window, axFrame: axFrame, at: point) }
        }
    }

    private func armDrag(window: AXUIElement, axFrame: CGRect?, at point: CGPoint) {
        guard settings.snapByDragging, let axFrame else { return }
        // The hit-test is asynchronous, so the button may already be back up by the time it lands.
        // Arming then would leave the session armed with no drag in progress, and the next
        // unrelated drag on the system would be treated as ours.
        guard !session.isArmed else { return }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = ScreenCoordinates.toCocoa(axFrame, primaryHeight: primaryHeight)

        draggedWindow = window
        draggedFrame = frame
        wasSnapped = settings.restoreSizeOnUnsnap && manipulator.isSnapped(window, at: frame)
        zoneRects = [:]
        zoneRectsScreen = nil
        // Pay the window server's first-show cost now, while nothing is waiting on it.
        footprint.prepare()
        _ = session.pressed(at: point)
    }

    func mouseDragged(to point: CGPoint) {
        guard session.isArmed, let window = draggedWindow else { return }

        let resolved = resolve(at: point)
        let zone = resolved?.zone
        activeScreen = resolved?.screen

        // "Restore size when unsnapped": a snapped window dragged away from its edge goes back to
        // the size it had before, under the pointer, rather than staying full-height.
        //
        // `wasSnapped` was decided when the drag was armed and is cleared the moment this fires.
        // It can only happen once per drag, and re-asking on every pointer move meant two blocking
        // Accessibility reads for most of the screen — the single biggest source of the lag.
        if wasSnapped, zone == nil, case .dragging = session.state {
            wasSnapped = false
            if manipulator.restoreSizeKeepingPointer(window, pointerX: cocoaX(of: point)) {
                // The window is a different size now, so every precomputed rect that depended on
                // it is stale.
                draggedFrame = manipulator.cocoaFrame(of: window) ?? draggedFrame
                zoneRects = [:]
                zoneRectsScreen = nil
            }
        }

        guard let effect = session.moved(to: point, zone: zone) else { return }
        apply(effect, window: window)
    }

    func mouseUp() {
        defer { finishDrag() }
        guard let window = draggedWindow, let effect = session.released() else { return }
        apply(effect, window: window)
    }

    /// Escape, or the feature being switched off mid-drag.
    func cancel() {
        if let effect = session.cancelled(), let window = draggedWindow {
            apply(effect, window: window)
        }
        finishDrag()
    }

    private func finishDrag() {
        draggedWindow = nil
        draggedFrame = nil
        wasSnapped = false
        previewedZone = nil
        activeScreen = nil
        zoneRects = [:]
        zoneRectsScreen = nil
        footprint.hide()
    }

    // MARK: - Effects

    private func apply(_ effect: SnapDragSession.Effect, window: AXUIElement) {
        switch effect {
        case .showFootprint(let zone), .moveFootprint(let zone):
            guard let rect = rect(for: zone) else { return }
            previewedZone = zone
            footprint.show(rect, animated: settings.animateFootprint && effect.isMove)
            if settings.hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }

        case .hideFootprint:
            previewedZone = nil
            footprint.hide()

        case .snap(let zone):
            footprint.hide()
            // The rect the footprint promised, applied verbatim. Recomputing here would re-read
            // the window's live frame, and any action that depends on its current position would
            // resolve differently at the drop than it did in the preview.
            guard let rect = rect(for: zone) else { return }
            manipulator.perform(rect: rect, on: window)
        }
    }

    /// The footprint and the drop read the same table, so the overlay cannot promise a rect the
    /// drop then declines to use.
    private func rect(for zone: SnapZone) -> CGRect? {
        guard let screen = activeScreen else { return nil }
        if zoneRectsScreen != screen.frame { rebuildZoneRects(for: screen) }
        return zoneRects[zone]
    }

    /// All nine rects for one screen, in one pass of pure arithmetic.
    ///
    /// Recomputed only when the drag crosses onto another display — never per pointer move, and
    /// never touching Accessibility.
    private func rebuildZoneRects(for screen: NSScreen) {
        zoneRects = [:]
        zoneRectsScreen = screen.frame
        guard let frame = draggedFrame else { return }

        let ultrawide = isUltrawide(screen)
        let context = WindowLayout.Context(
            visibleFrame: screen.visibleFrame,
            currentFrame: frame,
            isUltrawide: ultrawide,
            ultrawideMaxWidthFraction: maxWidthFraction()
        )
        for zone in SnapZone.allCases {
            let action = settings.action(for: zone, ultrawide: ultrawide)
            if let rect = WindowLayout.rect(for: action, in: context) {
                zoneRects[zone] = rect
            }
        }
    }

    // MARK: - Geometry

    /// `CGEvent.location` has its origin at the top-left of the primary display; `NSScreen` frames
    /// are bottom-left. Rather than convert the point, the zone test is told which space it is in —
    /// the conversion that isn't done can't be done wrongly.
    private func resolve(at point: CGPoint) -> (zone: SnapZone, screen: NSScreen)? {
        let screens = NSScreen.screens
        guard let resolved = SnapZoneLayout.resolve(
            at: point,
            screenFrames: screens.map(\.frame),
            primaryHeight: screens.first?.frame.height ?? 0
        ), let screen = screens.first(where: { $0.frame == resolved.screen })
        else { return nil }
        return (resolved.zone, screen)
    }

    private func cocoaX(of point: CGPoint) -> CGFloat { point.x }   // X is never flipped

    /// Ultrawide is decided from **the screen being dropped onto**, never from whether any
    /// ultrawide happens to be attached. A laptop alongside an ultrawide must keep its halves —
    /// that per-display rule is the whole reason the mode is safe to leave on, and a global check
    /// would break it in a way no single-display Mac could reveal.
    private func isUltrawide(_ screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        return SnapZoneLayout.usesUltrawideLayout(
            screen: screen.frame, settingEnabled: ultrawideEnabled()
        )
    }

    // MARK: - Accessibility

    /// The window whose titlebar is under the pointer, or nil for anything else — a click in a
    /// document, another app's toolbar button, our own panels.
    private nonisolated func titlebarWindow(at point: CGPoint) -> AXUIElement? {
        guard let element = AX.element(at: point),
              let pid = AX.pid(of: element),
              pid != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let role = AX.string(element, kAXRoleAttribute as String)
        // A titlebar drag hits either the window itself or its title bar; anything else — a button,
        // a text area, a scroll view — is not a window drag.
        guard role == (kAXWindowRole as String) || role == "AXToolbar"
                || AX.string(element, kAXSubroleAttribute as String) == "AXStandardWindow"
        else { return nil }

        if role == (kAXWindowRole as String) { return element }

        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &parent) == .success,
              let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
        else { return nil }
        return (parent as! AXUIElement)   // swiftlint:disable:this force_cast
    }
}

private extension SnapDragSession.Effect {
    /// Only a move between zones is worth animating; the first appearance should be immediate.
    var isMove: Bool {
        if case .moveFootprint = self { return true }
        return false
    }
}
