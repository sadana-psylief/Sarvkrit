import AppKit
import SwiftUI

/// The shelf window.
///
/// Modelled on `ClipboardPickerPanel` with one deliberate difference: **it does not dismiss when it
/// loses key focus.** The picker hides on `windowDidResignKey` because a picker that lingers after
/// you click away is a nuisance — but a shelf you have to keep re-summoning while you click into
/// Finder to find somewhere to put things is useless. Parking something is the *first* half of the
/// job; the panel has to survive until the second half.
///
/// Also `.stationary` rather than `.transient`: a transient panel is dismissed by the system on
/// Space changes, and dragging between Spaces is a real thing to do with a shelf.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfController: NSObject {
    static let shared = ShelfController()

    private var panel: ShelfPanel?
    private var feature: ShelfFeature?
    private var edgeStrips: [EdgeStripPanel] = []

    /// Width comes from the tile grid so the two can't disagree about how many columns fit.
    private static let size = CGSize(width: ShelfLayout.panelWidth, height: 340)

    func configure(feature: ShelfFeature) {
        self.feature = feature
    }

    // MARK: - Showing

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show(at point: CGPoint? = nil) {
        guard let feature else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Rebuilt every time, for the reason the clipboard picker records: a hidden window's
        // SwiftUI content doesn't reliably re-evaluate, so a panel built once showed a stale shelf.
        panel.contentView = NSHostingView(
            rootView: ShelfView(store: feature.store, feature: feature) { [weak self] in
                self?.hide()
            }
        )

        let anchor = point ?? NSEvent.mouseLocation
        if let screen = ScreenPlacement.screenUnderPointer() {
            panel.setFrameTopLeftPoint(ScreenPlacement.topLeft(
                forSize: Self.size, at: anchor, in: screen.visibleFrame
            ))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    // MARK: - Edge strips

    /// Puts an invisible, drag-accepting strip along the chosen edge of every screen.
    ///
    /// This is what makes the screen-edge trigger work **with no permissions at all**: a window
    /// registered for dragged types is told when a drag passes over it, so nothing needs to watch
    /// the mouse globally.
    func installEdgeStrips(on edge: ScreenPlacement.Edge, thickness: CGFloat) {
        removeEdgeStrips()
        for screen in NSScreen.screens {
            let frame = ScreenPlacement.strip(for: edge, in: screen.frame, thickness: thickness)
            let strip = EdgeStripPanel(frame: frame) { [weak self] in
                self?.show()
            }
            strip.orderFrontRegardless()
            edgeStrips.append(strip)
        }
    }

    func removeEdgeStrips() {
        edgeStrips.forEach { $0.orderOut(nil) }
        edgeStrips.removeAll()
    }

    /// Strips accept drags only while one is in progress. Inert, they'd never receive a drag at
    /// all; live, they'd swallow every click along a screen edge.
    func setEdgeStripsArmed(_ armed: Bool) {
        edgeStrips.forEach { $0.setArmed(armed) }
    }
}
