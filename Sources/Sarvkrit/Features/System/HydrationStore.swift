import Foundation
import os

/// The drinks log on disk. A single JSON file, written off the main thread by `CoalescingSaver`.
///
/// Not UserDefaults: ninety days of entries is a growing document, not a preference, and defaults
/// are read whole into memory by every process that touches the domain.
final class HydrationStore {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Water")
    private let fileURL: URL

    private(set) var contents: HydrationLog

    private lazy var saver = CoalescingSaver<HydrationLog>(
        label: "\(AppIdentity.bundleID).hydration-save"
    ) { [weak self] snapshot in
        self?.write(snapshot)
    }

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let directory = directory ?? Self.defaultDirectory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("log.json")
        contents = Self.read(from: fileURL)
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sarvkrit", isDirectory: true)
            .appendingPathComponent("Hydration", isDirectory: true)
    }

    /// Applies a change and schedules the write.
    func update(_ change: (inout HydrationLog) -> Void) {
        change(&contents)
        saver.schedule(contents)
    }

    func flush() { saver.flush() }

    private static func read(from url: URL) -> HydrationLog {
        guard let data = try? Data(contentsOf: url) else { return HydrationLog() }
        // A file that won't decode is treated as empty rather than fatal. It is a log of glasses of
        // water; refusing to start the feature over it would be out of all proportion.
        return (try? JSONDecoder.hydration.decode(HydrationLog.self, from: data)) ?? HydrationLog()
    }

    private func write(_ snapshot: HydrationLog) {
        do {
            let data = try JSONEncoder.hydration.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("couldn't save the water log: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static var hydration: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var hydration: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
