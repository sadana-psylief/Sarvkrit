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

    /// Whether the point falls inside any window this process owns.
    static func isPointOverOwnWindow(_ point: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return isPoint(point, overWindowsOf: ProcessInfo.processInfo.processIdentifier,
                       in: windows)
    }

    /// Pure, so the geometry can be tested without a window server.
    ///
    /// `kCGWindowBounds` and the coordinates `AXUIElementCopyElementAtPosition` takes are both
    /// top-left origin with y increasing downwards, which is the only reason one can stand in for
    /// the other.
    static func isPoint(_ point: CGPoint, overWindowsOf pid: pid_t,
                        in windows: [[String: Any]]) -> Bool {
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            if rect.contains(point) { return true }
        }
        return false
    }

    static func application(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Hit-test in global display coordinates. `CGEvent.location` is already in exactly this
    /// space (origin top-left), so no flipping is needed.
    /// The element at a screen point, or nil.
    ///
    /// **Never asks about our own windows, and that is what stops it crashing.**
    /// `AXUIElementCopyElementAtPosition` is answered *in-process* when the point is over a window
    /// this app owns: AppKit serves it synchronously on the calling thread, through
    /// `NSHostingView.accessibilityHitTest` and into SwiftUI, which evaluates a view body and
    /// asserts it is on the main actor. Both callers run this on a background queue on purpose —
    /// it costs up to four Accessibility round trips against an app that may be busy — so the
    /// answer arrives as a trap rather than an element.
    ///
    /// Both callers already discard our own process; neither could do it soon enough, because the
    /// PID they test belongs to the element this call was meant to return. So the question is
    /// answered here instead, with the window list — Core Graphics, no Accessibility, no SwiftUI,
    /// safe from any thread. Nothing wants our own windows anyway: the app cannot drive itself
    /// through the Accessibility API.
    static func element(at point: CGPoint) -> AXUIElement? {
        guard !isPointOverOwnWindow(point) else { return nil }
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
