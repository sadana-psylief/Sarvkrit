import ApplicationServices
import AppKit
import Foundation

/// Thin wrappers over the AXUIElement C API.
///
/// Every call here can block on the target process, so nothing in this file may be called
/// from the event tap callback. Callers hop to a background queue first.
enum AX {
    /// AX calls block until the target app answers. Left at the default (6s) a hung app
    /// would freeze whichever queue we're on, so every element we create is capped hard.
    private static let messagingTimeout: Float = 0.25

    static func systemWide() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Hit-test in global display coordinates. `CGEvent.location` is already in exactly this
    /// space (origin top-left), so no flipping is needed.
    static func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide(), Float(point.x), Float(point.y), &element
        )
        guard result == .success, let element else { return nil }
        // The cap has to be set on *this* element too. It doesn't inherit from the system-wide one
        // it came from, so without this every later `AX.string` on it waits the ~6s default against
        // an app that may be busy — on whichever queue asked.
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// Number of windows the app currently vends. Returns nil when the app can't be asked
    /// (quit already, or not AX-visible) — the caller must not treat that as "zero windows".
    static func windowCount(pid: pid_t) -> Int? {
        var value: CFTypeRef?
        let app = application(pid: pid)
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? [AXUIElement])?.count
    }

    /// Role of whatever is focused system-wide, e.g. "AXTextField" while renaming a file
    /// inline in Finder.
    static func focusedElementRole() -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide(), kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused else { return nil }
        // swiftlint:disable:next force_cast
        return string(focused as! AXUIElement, kAXRoleAttribute as String)
    }
}
