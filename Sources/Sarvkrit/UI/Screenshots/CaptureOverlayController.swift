import AppKit
import CoreGraphics
import os

/// The frozen screen, and the selection drawn on top of it.
///
/// **Freeze is the overlay, not a mode inside it.** Every display is captured once up front, each
/// gets a borderless panel showing its own frozen bitmap, and the selection is drawn over a static
/// image. That is what makes it possible to screenshot an open menu or a tooltip — they are
/// already in the bitmap by the time the pointer moves. It also means the magnifier and the
/// dimension readout are arithmetic over pixels we already hold, rather than a capture per frame.
///
/// The crop comes out of the bitmap that was shown, so what you saw is exactly what you get.
@MainActor
final class CaptureOverlayController: NSObject, SelectionViewDelegate {
    static let shared = CaptureOverlayController()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    private var panels: [FloatingPanel] = []
    private var frames: [CGDirectDisplayID: DisplayFrame] = [:]
    /// The picked window, when the overlay was presented in window mode. Handed back so the
    /// caller can take a *fresh* capture of it — see `selectionView(_:didConfirmWindow:)`.
    private var windowCompletion: ((CapturableWindow?) -> Void)?
    private var completion: ((CGImage?, DisplaySnapshotGeometry?, CGRect?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var cursorHidden = false

    var isPresenting: Bool { !panels.isEmpty }

    private var selectionMode: SelectionMode = .area

    /// Shows the overlay to pick a window, and hands the window back rather than an image.
    ///
    /// **Window mode freezes only to choose.** Cropping the window's rectangle out of the frozen
    /// desktop cannot give you shadow-off, and certainly cannot give you a transparent
    /// background — the desktop is *in* those pixels. So the frozen frame is used for hit-testing
    /// and highlighting, then thrown away, and the result comes from a fresh
    /// `SCContentFilter(desktopIndependentWindow:)` capture. Freeze is one input path and two
    /// output paths, and this is the second one.
    func presentWindowPicker(frames capturedFrames: [DisplayFrame],
                             windows: [CapturableWindow],
                             completion: @escaping (CapturableWindow?) -> Void) {
        windowCompletion = completion
        present(frames: capturedFrames,
                chrome: Chrome(showsCrosshair: false, showsMagnifier: false, showsDimensions: true),
                mode: .window(windows)) { _, _, _ in }
    }

    /// Shows the overlay over frozen bitmaps and calls back with the crop, or nil if cancelled.
    /// How the overlay is drawn. Carried in rather than read from a feature so the controller
    /// stays a UI object with no opinion about where settings live.
    struct Chrome {
        var showsCrosshair = true
        var showsMagnifier = true
        var showsDimensions = true
    }

    func present(frames capturedFrames: [DisplayFrame],
                 chrome: Chrome = Chrome(),
                 mode: SelectionMode = .area,
                 completion: @escaping (CGImage?, DisplaySnapshotGeometry?, CGRect?) -> Void) {
        dismiss()
        log.info("present \(capturedFrames.count, privacy: .public) frame(s)")
        guard !capturedFrames.isEmpty else { completion(nil, nil, nil); return }

        self.completion = completion
        self.selectionMode = mode
        self.frames = Dictionary(uniqueKeysWithValues:
            capturedFrames.map { ($0.geometry.displayID, $0) })

        for frame in capturedFrames {
            // The screen's own frame, not `visibleFrame`: the menu bar and the Dock are both
            // capturable, and an overlay that stopped short of them would leave live pixels
            // showing through at the edges of a frozen screen.
            let screenFrame = NSScreen.screen(for: frame.geometry.displayID)?.frame
                ?? frame.geometry.frame
            let panel = FloatingPanel(
                contentRect: screenFrame,
                style: .init(
                    // Above the menu bar, the Dock and Notification Center. `.floating` is not
                    // enough — the menu bar sits above it and would stay live over a frozen screen.
                    level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())),
                    // Escape, Return and the arrow keys all have to arrive.
                    acceptsKey: true,
                    clickThrough: false,
                    joinsAllSpaces: true,
                    hasShadow: false))

            let view = SelectionView(display: frame.geometry, frozenImage: frame.image, mode: mode)
            view.delegate = self
            view.showsCrosshair = chrome.showsCrosshair
            view.showsMagnifier = chrome.showsMagnifier
            view.showsDimensions = chrome.showsDimensions
            panel.contentView = view
            panel.setFrame(screenFrame, display: false)
            // `.ignoresCycle` so ⌘` doesn't cycle into a full-screen overlay panel.
            panel.collectionBehavior.insert(.ignoresCycle)
            // **Without this the crosshair and the magnifier never appear.** `mouseMoved` is not
            // delivered unless the window asks for it, and it defaults to off — so the view never
            // learned where the pointer was and drew neither, which looked like the features had
            // simply not been built.
            panel.acceptsMouseMovedEvents = true
            panel.orderFrontRegardless()
            panels.append(panel)

            // Key focus goes to the display the pointer is on, so Escape works without clicking.
            if screenFrame.contains(NSEvent.mouseLocation) {
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
            }
        }

        if panels.first(where: { $0.isKeyWindow }) == nil, let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }

        // Seed the pointer so the crosshair and loupe are on screen the instant the overlay opens,
        // rather than only after the first mouse movement.
        for panel in panels {
            (panel.contentView as? SelectionView)?.seedPointer(NSEvent.mouseLocation)
        }

        NSCursor.hide()
        cursorHidden = true
        installCancelObservers()
    }

    /// Tears the session down when the world changes underneath it.
    ///
    /// Both of these **cancel rather than recover**, deliberately. The frozen bitmaps describe an
    /// arrangement that no longer exists; re-snapshotting mid-drag would move the pixels out from
    /// under the user's selection, which is worse than making them press the shortcut again.
    private func installCancelObservers() {
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(with: nil, display: nil, rect: nil) }
            })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(with: nil, display: nil, rect: nil) }
            })
    }

    func dismiss() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observers = []
        panels.forEach { $0.orderOut(nil) }
        panels = []
        frames = [:]
        selectionMode = .area
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    // MARK: - SelectionViewDelegate

    func selectionView(_ view: SelectionView, didConfirm rect: CGRect) {
        // Crop out of the bitmap that was on screen, not a fresh capture: the whole point of
        // freezing is that what you selected is what you get.
        guard let frame = frames.values.first(where: { $0.geometry.frame.intersects(rect) }) else {
            finish(with: nil, display: nil, rect: nil)
            return
        }
        let snapped = CaptureGeometry.snapToPixelGrid(rect, in: frame.geometry)
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: snapped, in: frame.geometry)
        guard let cropped = frame.image.cropping(to: pixels.integral) else {
            log.error("crop fell outside the captured bitmap: \(pixels.debugDescription, privacy: .public)")
            finish(with: nil, display: nil, rect: nil)
            return
        }
        finish(with: cropped, display: frame.geometry, rect: snapped)
    }

    func selectionView(_ view: SelectionView, didConfirmWindow window: CapturableWindow) {
        let completion = windowCompletion
        windowCompletion = nil
        self.completion = nil
        dismiss()
        completion?(window)
    }

    func selectionViewDidCancel(_ view: SelectionView) {
        if let completion = windowCompletion {
            windowCompletion = nil
            self.completion = nil
            dismiss()
            completion(nil)
            return
        }
        finish(with: nil, display: nil, rect: nil)
    }

    private func finish(with image: CGImage?,
                        display: DisplaySnapshotGeometry?,
                        rect: CGRect?) {
        let completion = self.completion
        self.completion = nil
        // Dismiss before calling back: the callback may put a toast or a panel on screen, and it
        // must not appear underneath a full-screen overlay that is still up.
        dismiss()
        completion?(image, display, rect)
    }
}
