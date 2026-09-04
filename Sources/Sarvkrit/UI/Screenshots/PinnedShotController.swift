import AppKit
import SwiftUI

/// Every pinned screenshot currently on screen.
///
/// Owns *N* independent windows, each with its own opacity and lock state, which is why it is not
/// `ShelfController` with a different panel — that owns one window and toggles it.
@MainActor
final class PinnedShotController: NSObject {
    static let shared = PinnedShotController()

    /// One pinned window's state.
    ///
    /// **`ObservableObject`, and that is the whole bug fixed.** It was a plain class whose values
    /// the view read through `Binding(get:set:)` closures, so writing one changed the model and
    /// nothing else: SwiftUI had no reason to re-run `body`. The opacity slider did nothing, the
    /// lock chip never changed its symbol, and Lock Mode hid its own controls only in theory while
    /// `ignoresMouseEvents` made them dead in fact — a window that looked interactive, wasn't, and
    /// showed no sign of why. The only thing that ever redrew a pin was its own hover state, which
    /// is why moving the pointer away appeared to apply the opacity all at once.
    final class Pin: ObservableObject {
        let panel: FloatingPanel
        let id = UUID()
        @Published var opacity: Double = 1
        @Published var isLocked = false
        init(panel: FloatingPanel) { self.panel = panel }
    }

    private var pins: [Pin] = []

    var count: Int { pins.count }

    /// Pins an image, over the rect it was captured from when that is still on a display.
    ///
    /// Putting it back where it came from is the behaviour that makes pinning useful for
    /// comparisons — the copy lands exactly over the original.
    func pin(image: NSImage, sourceRect: CGRect?) {
        let size = fittedSize(for: image)
        let origin = startingOrigin(for: size, sourceRect: sourceRect)

        let panel = FloatingPanel(
            contentRect: NSRect(origin: origin, size: size),
            // Not key: a pinned screenshot is a reference you look at, and taking focus would put
            // it between the user and whatever they are actually typing into.
            style: .init(level: .floating, acceptsKey: false, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true, isResizable: true))
        let pin = Pin(panel: panel)

        panel.contentView = NSHostingView(rootView: PinnedShotView(
            pin: pin,
            image: image,
            onOpacityChange: { value in
                pin.opacity = PinnedShotGeometry.clampedOpacity(value)
            },
            onLockChange: { [weak self] locked in
                pin.isLocked = locked
                self?.applyLock(pin)
            },
            onClose: { [weak self] in self?.close(pin) },
            onCopy: {
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
            },
            onResize: { [weak self] delta in self?.resize(pin, by: delta) }))

        panel.orderFrontRegardless()
        pins.append(pin)
    }

    /// Lock Mode: clicks pass through to whatever is underneath.
    ///
    /// **The way back out is deliberately not a click on the pin**, because there isn't one — the
    /// window no longer accepts any. It is ⌃⇧P (unlock all), and the pin draws an accent border
    /// while locked so the state is visible. `EdgeStripPanel`'s comment records the same trap from
    /// the other direction: `ignoresMouseEvents` silently swallowing the interaction you needed.
    private func applyLock(_ pin: Pin) {
        pin.panel.ignoresMouseEvents = pin.isLocked
        if pin.isLocked {
            // Said at the moment it becomes true, because from then on the pin cannot be clicked
            // to ask. A locked window with no visible way out is the worst thing this feature can
            // leave behind.
            // **Only routes that exist are named.** ⌃⇧P is registered inside
            // `PinToScreenFeature.activate()`, so with that feature switched off the old wording
            // sent people to a hotkey that was never claimed — while they were looking at a window
            // that had just stopped accepting clicks. The guard's shortcut is installed
            // unconditionally at launch and is always true.
            let unlock = PinToScreenFeature.isUnlockShortcutRegistered
                ? "press ⌃⇧P to unlock, or \(CaptureOverlayGuard.shortcutDescription) to clear "
                    + "everything"
                : "press \(CaptureOverlayGuard.shortcutDescription) to unlock and clear everything"
            ToastPresenter.shared.show("Locked — \(unlock)", symbolName: "lock.fill")
        }
    }

    /// Unlocks everything. One of two ways out of Lock Mode — the other is
    /// `CaptureOverlayGuard`, which also closes them — and the reason it is safe to offer at all.
    func unlockAll() {
        for pin in pins where pin.isLocked {
            pin.isLocked = false
            pin.panel.ignoresMouseEvents = false
        }
    }

    func closeAll() {
        pins.forEach { $0.panel.orderOut(nil) }
        pins = []
    }

    private func close(_ pin: Pin) {
        pin.panel.orderOut(nil)
        pins.removeAll { $0 === pin }
    }

    private func resize(_ pin: Pin, by delta: CGSize) {
        let resized = PinnedShotGeometry.resized(pin.panel.frame, by: delta,
                                                 preservingAspect: true,
                                                 displays: NSScreen.screens.map(\.visibleFrame))
        pin.panel.setFrame(resized, display: true)
    }

    // MARK: - Placement

    /// Big screenshots get scaled down to something that fits comfortably; small ones are left
    /// alone. A pin the size of the whole display is not a reference, it is a wall.
    private func fittedSize(for image: NSImage) -> CGSize {
        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maximum = CGSize(width: visible.width * 0.5, height: visible.height * 0.5)
        let scale = min(1, min(maximum.width / max(image.size.width, 1),
                               maximum.height / max(image.size.height, 1)))
        return CGSize(width: max(PinnedShotGeometry.minimumSide, image.size.width * scale),
                      height: max(PinnedShotGeometry.minimumSide, image.size.height * scale))
    }

    private func startingOrigin(for size: CGSize, sourceRect: CGRect?) -> CGPoint {
        if let sourceRect,
           NSScreen.screens.contains(where: { $0.frame.intersects(sourceRect) }) {
            return CGPoint(x: sourceRect.minX, y: sourceRect.maxY - size.height)
        }
        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Cascade, so a second pin doesn't land exactly on the first and look like one window.
        let step = CGFloat(pins.count % 8) * 24
        return CGPoint(x: visible.midX - size.width / 2 + step,
                       y: visible.midY - size.height / 2 - step)
    }
}
