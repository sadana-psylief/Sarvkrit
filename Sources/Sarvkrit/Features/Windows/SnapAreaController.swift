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
    /// The rect the footprint is currently promising, so the drop applies exactly what was shown.
    private var previewedZone: SnapZone?

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

    func mouseDown(at point: CGPoint) {
        guard settings.snapByDragging else { return }
        // Hit-test now, while the titlebar is under the pointer and the app is still answering.
        // Waiting until the drag starts races the window moving out from under the point.
        guard let window = titlebarWindow(at: point) else { return }
        draggedWindow = window
        _ = session.pressed(at: point)
    }

    func mouseDragged(to point: CGPoint) {
        guard session.isArmed, let window = draggedWindow else { return }

        let zone = zone(at: point)

        // "Restore size when unsnapped": a snapped window dragged away from its edge goes back to
        // the size it had before, under the pointer, rather than staying full-height.
        if settings.restoreSizeOnUnsnap, zone == nil, case .dragging = session.state,
           manipulator.isSnapped(window) {
            _ = manipulator.restoreSizeKeepingPointer(window, pointerX: cocoaX(of: point))
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
        previewedZone = nil
        footprint.hide()
    }

    // MARK: - Effects

    private func apply(_ effect: SnapDragSession.Effect, window: AXUIElement) {
        switch effect {
        case .showFootprint(let zone), .moveFootprint(let zone):
            guard let rect = rect(for: zone, window: window) else { return }
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
            _ = manipulator.perform(
                settings.action(for: zone, ultrawide: isUltrawide(window)),
                ultrawideEnabled: ultrawideEnabled(),
                maxWidthFraction: maxWidthFraction(),
                window: window
            )
        }
    }

    /// The footprint and the drop go through the same call, so the overlay cannot promise a rect
    /// the drop then declines to use.
    private func rect(for zone: SnapZone, window: AXUIElement) -> CGRect? {
        manipulator.targetRect(
            for: settings.action(for: zone, ultrawide: isUltrawide(window)),
            window: window,
            ultrawideEnabled: ultrawideEnabled(),
            maxWidthFraction: maxWidthFraction()
        )
    }

    // MARK: - Geometry

    /// `CGEvent.location` has its origin at the top-left of the primary display; `NSScreen` frames
    /// are bottom-left. Rather than convert the point, the zone test is told which space it is in —
    /// the conversion that isn't done can't be done wrongly.
    private func zone(at point: CGPoint) -> SnapZone? {
        guard let screenFrame = screenFrameInAXSpace(containing: point) else { return nil }
        return SnapZoneLayout.zone(at: point, in: screenFrame, flipped: true)
    }

    private func screenFrameInAXSpace(containing point: CGPoint) -> CGRect? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            let axFrame = ScreenCoordinates.toAccessibility(screen.frame, primaryHeight: primaryHeight)
            if axFrame.contains(point) { return axFrame }
        }
        return nil
    }

    private func cocoaX(of point: CGPoint) -> CGFloat { point.x }   // X is never flipped

    private func isUltrawide(_ window: AXUIElement) -> Bool {
        guard ultrawideEnabled() else { return false }
        return NSScreen.screens.contains { WindowLayout.isUltrawide($0.frame) }
    }

    // MARK: - Accessibility

    /// The window whose titlebar is under the pointer, or nil for anything else — a click in a
    /// document, another app's toolbar button, our own panels.
    private func titlebarWindow(at point: CGPoint) -> AXUIElement? {
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
