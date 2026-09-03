import AppKit
import SwiftUI

/// The All-In-One capture bar: one shortcut, every mode.
@MainActor
final class AllInOneController: NSObject {
    static let shared = AllInOneController()

    private var panel: FloatingPanel?
    private var escapeMonitor: Any?

    var isPresenting: Bool { panel != nil }

    /// - Parameter completion: the chosen mode and timer, or nil if cancelled.
    func present(memory: CaptureModeMemory,
                 timerSeconds: Int,
                 completion: @escaping ((CaptureModeMemory, Int)?) -> Void) {
        dismiss()

        var finished = false
        let finish: ((CaptureModeMemory, Int)?) -> Void = { [weak self] result in
            // A mode cell fires on click and the escape monitor can fire in the same turn; without
            // this the completion would run twice and start two captures.
            guard !finished else { return }
            finished = true
            self?.dismiss()
            completion(result)
        }

        let content = AllInOnePickerView(
            memory: memory,
            timerSeconds: timerSeconds,
            onPick: { finish(($0, $1)) },
            onCancel: { finish(nil) })

        let hosting = NSHostingView(rootView: content)
        // Sized from the content rather than a guessed constant, so adding a mode cannot silently
        // clip the bar.
        let fitted = hosting.fittingSize
        // Room for the SwiftUI shadow, which is drawn inside the window and would otherwise be
        // cropped at the edges.
        let inset: CGFloat = 40
        let size = CGSize(width: fitted.width + inset * 2, height: fitted.height + inset * 2)

        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = FloatingPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2,
                                // Low on the screen, out of the way of what is being captured —
                                // a bar across the middle covers the thing you are aiming at.
                                y: visible.minY + 96,
                                width: size.width, height: size.height),
            style: .init(level: .modalPanel, acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true,
                         // The bars draw their own shadow; a window shadow would trace the
                         // transparent rectangle around them.
                         hasShadow: false))

        panel.contentView = NSHostingView(rootView: content.padding(inset))
        // Activating is deliberate and rare: the size fields are typed into, and
        // `MainWindowController` records that an .accessory app's windows never reliably take key
        // focus without it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // Escape
            finish(nil)
            return nil
        }
    }

    func dismiss() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
