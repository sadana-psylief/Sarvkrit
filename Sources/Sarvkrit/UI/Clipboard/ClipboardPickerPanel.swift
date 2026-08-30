import AppKit
import SwiftUI

/// A borderless panel that appears at the cursor, Spotlight-style.
///
/// Deliberately **not** built like `MainWindowController`. Switching the app to `.regular` would
/// flash a Dock icon and take frontmost status from the app you're about to paste into — exactly
/// what this must not do. A `.nonactivatingPanel` leaves the target app frontmost the whole time.
final class ClipboardPickerPanel: NSPanel {
    /// Borderless panels refuse key status by default. Without this override the search field
    /// silently never receives typing — every keystroke goes to the app behind, which looks like
    /// the panel is simply broken.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPickerController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPickerController()

    private var panel: ClipboardPickerPanel?
    private var feature: ClipboardFeature?
    private var keyMonitor: Any?

    /// Set by the picker view while it's on screen. Returns true if it consumed the digit.
    ///
    /// The view registers this rather than the controller reaching into it, because only the view
    /// knows the *currently visible* results — with a search query typed, ⌘1 must paste the first
    /// row you can see, not the first row in the store.
    var handleCommandDigit: ((Int) -> Bool)?


    func configure(feature: ClipboardFeature) {
        self.feature = feature
    }

    func show() {
        guard let feature else { return }

        let panel = self.panel ?? makePanel(for: feature)
        self.panel = panel

        // Sized to what it's about to show. It used to be a fixed 420pt whatever the contents, so
        // a handful of entries left roughly half the panel empty.
        let items = feature.store.ordered(
            sortedBy: feature.settings.sortMode, pinned: feature.settings.pinnedPosition)
        panel.setContentSize(ClipboardPickerLayout.panelSize(for: items, settings: feature.settings))

        // Rebuilt every time, not reused. A hidden window's SwiftUI content doesn't reliably
        // re-evaluate, so a panel built once kept showing the history as it was at first open —
        // which is why quitting and relaunching "fixed" it. Rebuilding also clears last time's
        // search text and selection, which should not persist between openings anyway.
        panel.contentView = NSHostingView(
            rootView: ClipboardPickerView(
                feature: feature,
                store: feature.store,
                onContentHeightChange: { [weak self] height in self?.resize(to: height) },
                dismiss: { [weak self] in self?.hide() }
            )
        )

        panel.setFrameTopLeftPoint(originAtCursor(for: panel))
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// Grows and shrinks as filtering changes the result count.
    ///
    /// The top-left is held fixed rather than the frame origin: the panel is positioned at the
    /// cursor, so it must extend downward as it grows instead of sliding up the screen.
    private func resize(to height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        guard abs(panel.frame.height - height) > 0.5 else { return }

        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(CGSize(width: ClipboardPickerLayout.width, height: height))
        panel.setFrameTopLeftPoint(topLeft)
    }

    /// ⌘1–5, handled with a local event monitor rather than SwiftUI's `onKeyPress`.
    ///
    /// ⌘-modified keys route through AppKit's `performKeyEquivalent` chain before ordinary keyDown
    /// dispatch, and `onKeyPress` has known gaps receiving them — the failure mode being that the
    /// handler simply never fires. A local monitor sees them reliably, and only while our panel is
    /// up, so ⌘1 keeps switching browser tabs everywhere else.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let digit = Int(event.charactersIgnoringModifiers ?? ""),
                  (1...5).contains(digit)
            else { return event }
            // Returning nil swallows it, so the digit never reaches the search field.
            return self.handleCommandDigit?(digit) == true ? nil : event
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    func hide() {
        removeKeyMonitor()
        handleCommandDigit = nil
        panel?.orderOut(nil)
    }

    private func makePanel(for _: ClipboardFeature) -> ClipboardPickerPanel {
        let panel = ClipboardPickerPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(
                width: ClipboardPickerLayout.width,
                height: ClipboardPickerLayout.minimumHeight)),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Follows the user to whichever Space they're on, rather than yanking them back.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        return panel
    }

    /// Top-left corner for the panel, clamped so it never opens off-screen — near a screen edge or
    /// the menu bar is exactly where a cursor often is.
    private func originAtCursor(for panel: NSPanel) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return mouse }

        let size = panel.frame.size
        // Offset slightly so the panel doesn't open under the pointer itself.
        var x = mouse.x + 8
        var y = mouse.y - 8

        if x + size.width > visible.maxX { x = max(visible.minX, mouse.x - size.width - 8) }
        if x < visible.minX { x = visible.minX }
        // y is the *top* edge here, so the panel extends downward from it.
        if y - size.height < visible.minY { y = min(visible.maxY, mouse.y + size.height + 8) }
        if y > visible.maxY { y = visible.maxY }

        return NSPoint(x: x, y: y)
    }

    /// Dismiss as soon as focus goes elsewhere — a picker that lingers after you click away is a
    /// nuisance, not a feature.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
