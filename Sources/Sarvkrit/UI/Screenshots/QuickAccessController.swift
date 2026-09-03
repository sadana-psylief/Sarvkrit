import AppKit
import SwiftUI

/// The thumbnails that appear in a screen corner after a capture.
///
/// **A separate controller from `ShelfController`, deliberately.** The Shelf owns exactly one
/// panel with a `toggle()`; this owns a stack of them, each with its own auto-close timer and its
/// own backing capture. Folding two lifecycles into one type would be worse than having two.
@MainActor
final class QuickAccessController: NSObject {
    static let shared = QuickAccessController()

    /// One thumbnail on screen.
    private final class Entry {
        let panel: FloatingPanel
        let itemID: UUID
        let shownAt = Date()
        var hoveredSince: Date?
        var timer: Timer?
        init(panel: FloatingPanel, itemID: UUID) {
            self.panel = panel
            self.itemID = itemID
        }
    }

    private var entries: [Entry] = []
    /// The last capture dismissed, so ⌃⇧Z can bring it back.
    private var lastClosed: UUID?
    private var hiddenTemporarily = false

    var corner: QuickAccessPlacement.Corner = .bottomRight
    /// Nil means "stay until dismissed".
    var autoCloseAfter: TimeInterval? = 8

    weak var store: CaptureHistoryStore?
    /// Nil until the editor half exists; the Annotate button hides while it is.
    var openEditor: ((CaptureHistoryItem) -> Void)?
    var pinToScreen: ((CaptureHistoryItem) -> Void)?

    private static let panelSize = CGSize(width: 216, height: 178)

    // MARK: - Showing

    func show(_ item: CaptureHistoryItem) {
        guard let store, !hiddenTemporarily else { return }
        guard let image = NSImage(contentsOf: store.url(for: item)) else { return }

        // The screen the pointer is on, which is the one being worked on — not NSScreen.main,
        // which is whichever has key focus. `ScreenPlacement` records the same reasoning.
        guard let screen = ScreenPlacement.screenUnderPointer() else { return }

        let index = entries.count
        guard let offset = QuickAccessPlacement.stackOffset(
            forIndex: index, size: Self.panelSize, corner: corner, in: screen.visibleFrame)
        else {
            // The stack has filled the screen: the newest replaces the oldest rather than walking
            // off the edge.
            if let oldest = entries.first { close(oldest, remember: false) }
            show(item)
            return
        }

        let origin = QuickAccessPlacement.origin(forSize: Self.panelSize, corner: corner,
                                                 in: screen.visibleFrame)
        let panel = FloatingPanel(
            contentRect: NSRect(origin: CGPoint(x: origin.x + offset.width,
                                                y: origin.y + offset.height),
                                size: Self.panelSize),
            // Not key: the overlay must never steal focus from what the user is typing into. Every
            // action on it is a click, so it does not need keyboard input.
            style: .init(level: .floating, acceptsKey: false, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true))

        let entry = Entry(panel: panel, itemID: item.id)
        panel.contentView = NSHostingView(rootView: QuickAccessView(
            image: image,
            fileURL: store.url(for: item),
            dimensions: item.dimensionText,
            onAnnotate: openEditor.map { open in { [weak self] in
                open(item)
                self?.close(itemID: item.id, remember: false)
            } },
            onPin: pinToScreen.map { pin in { [weak self] in
                pin(item)
                self?.close(itemID: item.id, remember: false)
            } },
            onCopy: { [weak self] in
                if let image = NSImage(contentsOf: store.url(for: item)),
                   let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(png, forType: .png)
                }
                self?.close(itemID: item.id, remember: false)
            },
            onReveal: {
                NSWorkspace.shared.activateFileViewerSelecting([store.url(for: item)])
            },
            onDelete: { [weak self] in
                store.remove(id: item.id)
                self?.close(itemID: item.id, remember: false)
            },
            onHoverChange: { [weak self] hovering in
                self?.setHovering(hovering, for: item.id)
            }))

        panel.orderFrontRegardless()
        entries.append(entry)
        scheduleAutoClose(for: entry)
    }

    /// Brings back the capture that was closed last.
    func restoreLastClosed() {
        guard let id = lastClosed, let item = store?.items.first(where: { $0.id == id })
        else { return }
        lastClosed = nil
        show(item)
    }

    /// Hides every overlay until the next capture — for when they are in the way of the thing
    /// being screenshotted.
    func hideAll() {
        hiddenTemporarily = true
        entries.forEach { $0.timer?.invalidate(); $0.panel.orderOut(nil) }
        entries = []
    }

    func allowShowingAgain() { hiddenTemporarily = false }

    // MARK: - Closing

    private func scheduleAutoClose(for entry: Entry) {
        entry.timer?.invalidate()
        guard autoCloseAfter != nil else { return }
        // Polled rather than a one-shot timer, because hovering pauses the countdown and a
        // one-shot would have to be cancelled and re-armed with recomputed time on every hover.
        // The *id* is captured, not the entry: `Entry` is a main-actor class and a Timer's
        // closure is @Sendable. Looking it up each tick also means the timer can never act on an
        // entry that has already been closed.
        let itemID = entry.itemID
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let entry = self.entries.first(where: { $0.itemID == itemID }) else { return }
                if QuickAccessTimer.hasExpired(now: Date(), shownAt: entry.shownAt,
                                               duration: self.autoCloseAfter,
                                               hoveredSince: entry.hoveredSince) {
                    self.close(entry, remember: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        entry.timer = timer
    }

    private func setHovering(_ hovering: Bool, for itemID: UUID) {
        guard let entry = entries.first(where: { $0.itemID == itemID }) else { return }
        let itemID = entry.itemID
        if hovering {
            entry.hoveredSince = entry.hoveredSince ?? Date()
        } else if let since = entry.hoveredSince {
            // Give back the time spent hovering by sliding the start forward, so leaving the
            // pointer resumes the countdown from where it paused instead of restarting it.
            let paused = Date().timeIntervalSince(since)
            entry.hoveredSince = nil
            entry.timer?.invalidate()
            let adjusted = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          let entry = self.entries.first(where: { $0.itemID == itemID })
                    else { return }
                    if QuickAccessTimer.hasExpired(
                        now: Date().addingTimeInterval(-paused), shownAt: entry.shownAt,
                        duration: self.autoCloseAfter, hoveredSince: nil) {
                        self.close(entry, remember: true)
                    }
                }
            }
            RunLoop.main.add(adjusted, forMode: .common)
            entry.timer = adjusted
        }
    }

    func close(itemID: UUID, remember: Bool) {
        guard let entry = entries.first(where: { $0.itemID == itemID }) else { return }
        close(entry, remember: remember)
    }

    private func close(_ entry: Entry, remember: Bool) {
        entry.timer?.invalidate()
        entry.panel.orderOut(nil)
        entries.removeAll { $0 === entry }
        if remember { lastClosed = entry.itemID }
        restack()
    }

    /// Closing one from the middle would otherwise leave a hole in the pile.
    private func restack() {
        guard let screen = ScreenPlacement.screenUnderPointer() else { return }
        let origin = QuickAccessPlacement.origin(forSize: Self.panelSize, corner: corner,
                                                 in: screen.visibleFrame)
        for (index, entry) in entries.enumerated() {
            guard let offset = QuickAccessPlacement.stackOffset(
                forIndex: index, size: Self.panelSize, corner: corner, in: screen.visibleFrame)
            else { continue }
            entry.panel.setFrameOrigin(CGPoint(x: origin.x + offset.width,
                                               y: origin.y + offset.height))
        }
    }

    func closeAll() {
        entries.forEach { $0.timer?.invalidate(); $0.panel.orderOut(nil) }
        entries = []
    }
}
