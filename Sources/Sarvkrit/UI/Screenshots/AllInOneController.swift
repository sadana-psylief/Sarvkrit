import AppKit
import SwiftUI

/// The All-In-One picker: one shortcut, every mode.
@MainActor
final class AllInOneController: NSObject {
    static let shared = AllInOneController()

    private var panel: FloatingPanel?

    var isPresenting: Bool { panel != nil }

    /// - Parameter completion: the chosen mode and timer, or nil if cancelled.
    func present(memory: CaptureModeMemory,
                 timerSeconds: Int,
                 completion: @escaping ((CaptureModeMemory, Int)?) -> Void) {
        dismiss()

        let size = CGSize(width: 380, height: 200)
        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = FloatingPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2,
                                y: visible.midY - size.height / 2,
                                width: size.width, height: size.height),
            // Key, because the Capture and Cancel buttons have keyboard equivalents and Escape
            // has to close it.
            style: .init(level: .modalPanel, acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true))

        panel.contentView = NSHostingView(rootView: AllInOnePickerView(
            memory: memory,
            timerSeconds: timerSeconds,
            onPick: { [weak self] picked, seconds in
                self?.dismiss()
                completion((picked, seconds))
            },
            onCancel: { [weak self] in
                self?.dismiss()
                completion(nil)
            }))

        // Activating is the one place this app does so on purpose: the picker has text fields, and
        // MainWindowController records that an .accessory app's windows never reliably take key
        // focus. Without this the width and height fields cannot be typed into.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
