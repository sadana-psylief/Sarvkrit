import Foundation
import os

/// Watches folders and reports paths that changed.
///
/// FSEvents rather than a poll: a poll over a large Downloads folder is exactly the kind of
/// background cost this app spent a session removing.
///
/// Events are coalesced before they reach the engine. A single download can produce a burst of
/// writes, and running the rules on every one of them would be both wasteful and a good way to act
/// on a half-written file.
final class FolderWatcher {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "FolderWatcher")
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).folder-watcher")

    private var stream: FSEventStreamRef?
    private var pending: Set<URL> = []
    private var flushWorkItem: DispatchWorkItem?

    /// How long to wait for a burst to settle before reporting. Also the reason a file gets a
    /// second look, which is what `FileStabilityTracker` needs to confirm it stopped growing.
    private let coalesceInterval: TimeInterval
    private let onChange: ([URL]) -> Void

    init(coalesceInterval: TimeInterval = 1.0, onChange: @escaping ([URL]) -> Void) {
        self.coalesceInterval = coalesceInterval
        self.onChange = onChange
    }

    deinit { stop() }

    @discardableResult
    func start(watching folders: [URL]) -> Bool {
        stop()
        guard !folders.isEmpty else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // The stream is created with kFSEventStreamCreateFlagUseCFTypes, so `paths` is a
            // CFArray of CFStrings — NOT the char** the C signature suggests. Reading it as
            // C strings segfaults on the first event.
            guard let pathStrings = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            watcher.enqueue(pathStrings.map { URL(fileURLWithPath: $0) })
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            folders.map(\.path) as CFArray,
            // Only events from now on. Replaying history would mean acting on every file that ever
            // passed through the folder the first time a rule is switched on.
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            coalesceInterval / 2,
            flags
        ) else {
            log.error("could not create FSEvent stream")
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            log.error("could not start FSEvent stream")
            return false
        }

        self.stream = stream
        log.info("watching \(folders.count) folder(s)")
        return true
    }

    func stop() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func enqueue(_ urls: [URL]) {
        queue.async {
            self.pending.formUnion(urls)
            self.flushWorkItem?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let batch = self.pending
                self.pending.removeAll()
                guard !batch.isEmpty else { return }
                self.onChange(Array(batch).sorted { $0.path < $1.path })
            }
            self.flushWorkItem = work
            self.queue.asyncAfter(deadline: .now() + self.coalesceInterval, execute: work)
        }
    }
}
