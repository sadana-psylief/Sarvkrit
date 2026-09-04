import AppKit
import SwiftUI
import os

/// One editor window.
///
/// Modelled on `MainWindowController` rather than on the picker panels: this window genuinely
/// wants focus, a title bar, and a close button.
///
/// **Key handling does not assume a menu bar exists.** Whether a `MenuBarExtra`-only app acquires
/// a real main menu when the activation policy flips is not something to depend on, so the
/// command keys are intercepted in `performKeyEquivalent(with:)` — which AppKit offers to the
/// window's view hierarchy *before* the main menu — and the single-key tool shortcuts go through
/// `keyDown`. ⌘W in particular does nothing at all without a menu item, so intercepting it is
/// mandatory rather than a nicety.
@MainActor
final class ScreenshotEditorWindowController: NSObject, NSWindowDelegate {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    let model: EditorDocumentModel
    private var window: NSWindow?
    private var monitor: Any?
    private let onClose: (ScreenshotEditorWindowController) -> Void
    private let onCommit: (CGImage, UUID?) -> Void

    init(model: EditorDocumentModel,
         onCommit: @escaping (CGImage, UUID?) -> Void,
         onClose: @escaping (ScreenshotEditorWindowController) -> Void) {
        self.model = model
        self.onCommit = onCommit
        self.onClose = onClose
        super.init()
    }

    /// Fits the named tool row with a little slack. Below this the palette starts scrolling and
    /// tools disappear silently, which is the one thing this window must not do.
    static let minimumWidth: CGFloat = 890

    func show() {
        // Wide enough for the tool row, whatever the capture's size. A window sized only to a
        // small screenshot left most of the palette scrolled out of sight, which is the problem
        // naming the tools was meant to solve.
        let size = NSSize(width: min(1100, max(Self.minimumWidth,
                                               CGFloat(model.base.width) / 2 + 80)),
                          height: min(800, CGFloat(model.base.height) / 2 + 140))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: Self.minimumWidth, height: 400)
        window.contentView = NSHostingView(rootView: ScreenshotEditorView(
            model: model,
            presets: Self.presets,
            onSave: { [weak self] in self?.save(editable: false) },
            onSaveEditable: { [weak self] in self?.save(editable: true) },
            onCopy: { [weak self] in self?.copyToPasteboard() }))
        window.delegate = self
        // Cascade, so a second editor doesn't land exactly on the first and look like one window.
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(Self.openCount % 6) * 24,
                                      y: window.frame.minY - CGFloat(Self.openCount % 6) * 24))
        self.window = window

        // Through the lease: the settings window may also be open, and an unconditional drop back
        // to .accessory when *it* closes would leave this window refusing input.
        ActivationPolicyLease.shared.acquire()
        Self.openCount += 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        installKeyMonitor()
    }

    private static var openCount = 0
    /// Shared across editors: presets are a user setting, not per-document state.
    private static let presets = BackgroundPresetStore()

    // MARK: - Keys

    /// A local monitor rather than a menu: the app has no main menu to hang items on, and this is
    /// the same mechanism `ShortcutRecorderView` and the clipboard picker already use.
    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard let action = EditorKeyRouting.action(
                forCharacters: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags,
                isEditingText: self.model.isEditingText) else { return event }
            self.perform(action)
            return nil
        }
    }

    private func perform(_ action: EditorKeyRouting.Action) {
        switch action {
        case .selectTool(let tool): model.tool = tool
        case .selectColour(let index):
            guard (1...min(6, AnnotationPalette.colours.count)).contains(index) else { return }
            model.colour = AnnotationPalette.colours[index - 1]
            model.applyStyleToSelection()
        case .undo: model.undo()
        case .redo: model.redo()
        case .copy: copyToPasteboard()
        case .save: save(editable: false)
        case .saveEditable: save(editable: true)
        case .close: window?.performClose(nil)
        case .selectAll: model.selection = model.document.drawable.last?.id
        case .duplicate: model.duplicateSelection()
        case .deleteSelection: model.deleteSelection()
        case .cancel: model.selection = nil
        }
    }

    // MARK: - Output

    private func copyToPasteboard() {
        guard let flattened = model.flattenWithBackground(),
              let data = try? CaptureDocumentFile.encodeFlat(flattened) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        ToastPresenter.shared.show("Copied", symbolName: "doc.on.doc")
    }

    private func save(editable: Bool) {
        guard let flattened = model.flattenWithBackground() else { return }
        onCommit(flattened, model.historyItemID)
        model.markSaved()

        if editable {
            // Only this path pays the ~2x file size for the embedded base bitmap and document.
            guard let data = try? CaptureDocumentFile.encode(document: model.document,
                                                             base: model.base,
                                                             flattened: flattened) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Screenshot.png"
            panel.allowedContentTypes = [.png]
            panel.message = "Saved this way, Sarvkrit can reopen it with the annotations editable."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url, options: .atomic)
            ToastPresenter.shared.show("Saved, still editable", symbolName: "square.and.pencil")
        } else {
            ToastPresenter.shared.show("Saved", symbolName: "square.and.arrow.down")
        }
    }

    // MARK: - Lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to this screenshot?"
        alert.informativeText = "Your annotations will be lost otherwise."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(editable: false)
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ActivationPolicyLease.shared.release()
        onClose(self)
    }
}

/// Every open editor.
@MainActor
final class ScreenshotEditorController {
    static let shared = ScreenshotEditorController()

    private var controllers: [ScreenshotEditorWindowController] = []

    /// Called when an edit is saved, so the history entry can be rewritten in place.
    var commitEdit: ((CGImage, UUID?) -> Void)?

    var openCount: Int { controllers.count }

    func open(image: CGImage, document: AnnotationDocument? = nil, historyItemID: UUID? = nil) {
        let model = EditorDocumentModel(base: image, document: document,
                                        historyItemID: historyItemID)
        let controller = ScreenshotEditorWindowController(
            model: model,
            onCommit: { [weak self] flattened, id in self?.commitEdit?(flattened, id) },
            onClose: { [weak self] controller in
                self?.controllers.removeAll { $0 === controller }
            })
        controllers.append(controller)
        controller.show()
    }

    /// Reopens a saved capture, with its annotations if it has any.
    func open(fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        let contents = try CaptureDocumentFile.decode(data)
        open(image: contents.base ?? contents.flattened, document: contents.document)
    }

    /// Combines several captures into one and opens the result.
    ///
    /// The combined image becomes the base bitmap of a brand-new document, which is why this
    /// needs no special handling anywhere else: the Background tool, every annotation tool, OCR
    /// and the file format all apply to it exactly as they would to a single capture.
    func open(combining images: [CGImage],
              mode: CombineLayout.Mode = .vertical,
              spacing: CGFloat = 24,
              normalize: CombineLayout.Normalize = .widest) {
        guard let combined = ImageCombiner.render(images, mode: mode, spacing: spacing,
                                                  normalize: normalize,
                                                  backgroundColour: .white) else { return }
        open(image: combined)
    }
}
