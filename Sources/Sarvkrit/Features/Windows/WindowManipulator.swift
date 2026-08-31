import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads and writes the focused window's frame through the Accessibility API.
///
/// Every call here can block on the target process, so nothing in this file may run on the event
/// tap callback — `WindowFeature` decides synchronously and dispatches here afterwards.
final class WindowManipulator {

    /// Pre-snap frames, so `Restore` can put a window back where it was.
    ///
    /// `AXUIElement` is `Hashable` in Swift (bridged to `CFHash`/`CFEqual`), so the element itself
    /// is the key. There is no public window ID to use instead. Entries for windows that have since
    /// closed simply go stale and are cleared with the feature.
    private var memory = RestoreMemory<AXUIElement>()

    func forget() { memory.removeAll() }

    /// The screen origin for the Accessibility flip is the top-left of the **primary** display, so
    /// this is `screens[0]`'s `frame` — not `visibleFrame`, whose menu-bar inset would shift every
    /// window by 25 points, and not the target screen's height, which is only correct by accident
    /// on a single-display Mac.
    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    @discardableResult
    func perform(
        _ action: WindowAction,
        ultrawideEnabled: Bool,
        maxWidthFraction: CGFloat = 2.0 / 3.0
    ) -> Bool {
        guard let window = focusedWindow() else { return false }
        // Ask before touching anything: a window that can't be resized should be left entirely
        // alone rather than moved and then found to be unresizable halfway through.
        guard isSettable(window, kAXPositionAttribute), isSettable(window, kAXSizeAttribute),
              let currentAX = frame(of: window)
        else { return false }

        let screens = NSScreen.screens.map(\.frame)
        guard !screens.isEmpty else { return false }
        let height = primaryHeight
        let current = ScreenCoordinates.toCocoa(currentAX, primaryHeight: height)

        // Containment is judged against full `frame`s; layout against `visibleFrame`. Mixing the
        // two makes a window near the Dock look like it belongs to the neighbouring display.
        guard let screenFrame = ScreenCoordinates.screen(containing: current, screens: screens),
              let screen = NSScreen.screens.first(where: { $0.frame == screenFrame })
        else { return false }

        let target: CGRect
        if action.isDisplayMove {
            guard let moved = displayMove(action, current: current, from: screenFrame, screens: screens)
            else { return false }
            target = moved
        } else if action == .restore {
            guard let remembered = memory.restoreFrame(for: window) else { return false }
            target = remembered
        } else {
            let context = WindowLayout.Context(
                visibleFrame: screen.visibleFrame,
                currentFrame: current,
                isUltrawide: ultrawideEnabled && WindowLayout.isUltrawide(screen.frame),
                ultrawideMaxWidthFraction: maxWidthFraction
            )
            guard let rect = WindowLayout.rect(for: action, in: context) else { return false }
            target = rect
        }

        if action == .restore {
            memory.markRestored(window)
        } else {
            memory.record(window, current: current, target: target)
        }
        apply(ScreenCoordinates.toAccessibility(target, primaryHeight: height), to: window)
        return true
    }

    /// Moving to another display keeps the window's relative position and proportions — a window
    /// filling half a small screen should fill half the big one, not keep its pixel size and look
    /// lost.
    private func displayMove(
        _ action: WindowAction, current: CGRect, from screenFrame: CGRect, screens: [CGRect]
    ) -> CGRect? {
        guard let destination = ScreenCoordinates.adjacentScreen(
            to: screenFrame, screens: screens, forward: action == .nextDisplay
        ) else { return nil }   // single display: do nothing rather than something surprising
        let moved = ScreenCoordinates.translate(current, from: screenFrame, to: destination)
        let visible = NSScreen.screens.first { $0.frame == destination }?.visibleFrame ?? destination
        return WindowLayout.clamped(moved, to: visible)
    }

    // MARK: - Accessibility

    private func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        // Our own panels — the clipboard picker, a toast — are never what the user meant to move.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AX.application(pid: pid), kAXFocusedWindowAttribute as CFString, &value
        ) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)   // swiftlint:disable:this force_cast
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = point(window, kAXPositionAttribute),
              let size = size(window, kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var result = CGPoint.zero
        guard let value = attributeValue(element, attribute),
              AXValueGetValue(value, .cgPoint, &result) else { return nil }
        return result
    }

    private func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var result = CGSize.zero
        guard let value = attributeValue(element, attribute),
              AXValueGetValue(value, .cgSize, &result) else { return nil }
        return result
    }

    /// Returns nil rather than force-casting: an app can answer `.success` with a value of an
    /// entirely different type, and a force cast would turn that into a crash.
    private func attributeValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)   // swiftlint:disable:this force_cast
    }

    /// Size, then position, then size again.
    ///
    /// Not superstition: a window whose current size doesn't fit the destination can have its
    /// position clamped by its own app, and one that's being enlarged can have the new size
    /// refused while it's still in the old spot. Sizing twice around the move satisfies both
    /// orders, and costs one extra AX round trip on an action the user takes by hand.
    private func apply(_ rect: CGRect, to window: AXUIElement) {
        setSize(rect.size, on: window)
        setPosition(rect.origin, on: window)
        setSize(rect.size, on: window)
    }

    private func setPosition(_ point: CGPoint, on window: AXUIElement) {
        var value = point
        guard let ax = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, ax)
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) {
        var value = size
        guard let ax = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, ax)
    }
}
