import AppKit
import SwiftUI
import os

/// One editor window.
///
/// Modelled on `ScreenshotEditorWindowController`: a real `NSWindow`, through
/// `ActivationPolicyLease`, with keys intercepted by a local monitor because a `MenuBarExtra`
/// accessory has no main menu to hang items on — ⌘W in particular does nothing without one, so
/// intercepting it is mandatory rather than a nicety.
@MainActor
final class StudioEditorWindowController: NSObject, NSWindowDelegate {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Studio")

    let model: StudioDocumentModel
    private var window: NSWindow?
    private var monitor: Any?
    private var preview: StudioPreviewView?
    private let exporter = StudioExporter()
    private let onClose: (StudioEditorWindowController) -> Void

    /// Below this the timeline and the inspector both start hiding controls silently, which is the
    /// one thing this window must not do.
    static let minimumSize = NSSize(width: 1100, height: 700)

    init(model: StudioDocumentModel, onClose: @escaping (StudioEditorWindowController) -> Void) {
        self.model = model
        self.onClose = onClose
        super.init()
    }

    func show() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1240, height: 820)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Recording"
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize

        let root = StudioEditorView(
            model: model,
            onExport: { [weak self] in self?.export() },
            onPlayPause: { [weak self] in self?.togglePlayback() },
            onScrub: { [weak self] time in self?.preview?.scrub(to: time) })
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.delegate = self
        window.center()
        // Cascade, so a second editor does not land exactly on the first and look like one window.
        window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(Self.openCount % 6) * 24,
                                      y: window.frame.minY - CGFloat(Self.openCount % 6) * 24))
        self.window = window
        self.preview = hosting.findPreview()

        // Through the lease: another window may also be open, and an unconditional drop back to
        // .accessory when it closes would leave this one refusing input.
        ActivationPolicyLease.shared.acquire()
        Self.openCount += 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    private static var openCount = 0

    // MARK: - Playback

    private func togglePlayback() {
        guard let preview else { return }
        if model.isPlaying { preview.pause() } else { preview.play() }
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard let action = StudioKeyRouting.action(
                forCharacters: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags,
                // No text field in this window yet; when the transcript editor lands this becomes
                // the check that stops a caption edit splitting the timeline.
                isEditingText: false) else { return event }
            self.perform(action)
            return nil
        }
    }

    private func perform(_ action: StudioKeyRouting.Action) {
        switch action {
        case .playPause: togglePlayback()
        case .stepFrames(let count): model.step(frames: count)
        case .stepSeconds(let count): model.step(seconds: Double(count))
        case .shuttle(let direction):
            preview?.setRate(Float(direction))
        case .split: model.split()
        case .rippleDelete, .deleteSelection:
            if model.selectedZoom != nil { model.deleteSelectedZoom() } else {
                model.deleteSelectedClip()
            }
        case .addZoom: model.addZoomAtPlayhead()
        case .setZoomLevel(let digit):
            // 1 is 1x and each step is a quarter, which puts the useful range on the home row.
            model.setLevelOfSelectedZoom(1 + Double(max(0, digit - 1)) * 0.25)
        case .undo: model.undo()
        case .redo: model.redo()
        case .save: model.markSaved()
        case .export: export()
        case .close: window?.performClose(nil)
        case .setIn, .setOut, .fitTimeline, .loopPlayback, .copyFrame,
             .resetEdits, .showShortcuts, .commandMenu:
            // Not yet wired. Deliberately silent rather than half-done.
            break
        }
    }

    // MARK: - Export

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Recording.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.message = "1080p H.264 — plays everywhere."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        model.exportProgress = 0
        let project = model.project
        let events = model.events
        let bundle = model.bundle

        Task { [exporter, weak self] in
            do {
                try await exporter.export(
                    project: project, events: events, recording: bundle,
                    preset: .web, to: url,
                    onProgress: { progress in
                        Task { @MainActor in self?.model.exportProgress = progress.fraction }
                    })
                await MainActor.run {
                    self?.model.exportProgress = nil
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    ToastPresenter.shared.show("Exported", symbolName: "square.and.arrow.up")
                }
            } catch {
                await MainActor.run {
                    self?.model.exportProgress = nil
                    ToastPresenter.shared.show("Export failed",
                                               symbolName: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: - Lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The project autosaves into the bundle continuously, so there is nothing to lose and
        // nothing to ask about. A dialog here would be ceremony over a decision already made.
        model.markSaved()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        preview?.pause()
        ActivationPolicyLease.shared.release()
        onClose(self)
    }
}

private extension NSView {
    /// The hosting view builds the tree, so the preview has to be found rather than held.
    func findPreview() -> StudioPreviewView? {
        if let preview = self as? StudioPreviewView { return preview }
        for child in subviews {
            if let found = child.findPreview() { return found }
        }
        return nil
    }
}

/// Every open editor.
@MainActor
final class StudioEditorController {
    static let shared = StudioEditorController()

    private var controllers: [StudioEditorWindowController] = []

    var openCount: Int { controllers.count }

    /// Opens a finished recording.
    func open(_ bundle: RecordingBundle) {
        guard let manifest = try? bundle.readManifest() else { return }
        let events = (try? bundle.readEvents()) ?? EventLog()
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: events)
        let controller = StudioEditorWindowController(model: model) { [weak self] finished in
            self?.controllers.removeAll { $0 === finished }
        }
        controllers.append(controller)
        controller.show()
    }
}
