import AppKit
import Foundation

/// Watches the pasteboard for new copies.
///
/// `NSPasteboard` has no change notification — polling `changeCount` is what every clipboard
/// manager does. Only runs while the feature is on.
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    /// A change count this monitor should ignore, set by the paster: putting an item back on the
    /// pasteboard to paste it would otherwise be recorded as a brand-new copy.
    private var suppressedChangeCount: Int?

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let onCopy: (ClipboardCapturePolicy.Snapshot) -> Void

    init(
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.4,
        onCopy: @escaping (ClipboardCapturePolicy.Snapshot) -> Void
    ) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.onCopy = onCopy
        // Start from where the pasteboard is now: whatever is already on it wasn't copied while
        // we were watching, and recording it at launch would be a surprise.
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called by the paster before it writes, so the resulting change isn't recorded as a new copy.
    func suppressNextChange() {
        suppressedChangeCount = pasteboard.changeCount + 1
    }

    private func poll() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        if let suppressed = suppressedChangeCount, suppressed == current {
            suppressedChangeCount = nil
            return
        }

        // Types first, content second. The privacy filter has to be able to refuse a copy before
        // its content is ever read into this process.
        let (types, declaredSource) = PasteboardReader.typesAndSource(of: pasteboard)
        let source = ClipboardPrivacyFilter.resolveSource(
            declared: declaredSource, frontmost: FrontmostAppMonitor.shared.bundleID)

        var snapshot = ClipboardCapturePolicy.Snapshot(types: types, declaredSource: source)
        snapshot.declaredSource = source
        onCopy(snapshot)
    }

    /// Reads the full content of the current pasteboard — the feature calls this only after the
    /// filter has approved.
    func readContent(types: [String], source: String?) -> ClipboardCapturePolicy.Snapshot {
        PasteboardReader.snapshot(of: pasteboard, types: types, source: source)
    }

    func pngPayload() -> Data? { PasteboardReader.pngData(from: pasteboard) }
    func rtfPayload() -> Data? { pasteboard.data(forType: .rtf) }
}
