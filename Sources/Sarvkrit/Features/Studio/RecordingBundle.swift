import CoreGraphics
import Foundation

/// The buffer size a recording should ask for.
///
/// Sibling of `CaptureConfigurationMath`, with one rule a screenshot does not need: **the result
/// is always even.** H.264 and HEVC work in macroblocks, so an odd dimension makes the encoder pad
/// the frame — and unlike an export, the recording is the master everything else is derived from,
/// so the cost is paid by every zoom and every export made from it afterwards.
enum RecordingGeometry {
    static func pixelSize(contentRect: CGRect, pointPixelScale: CGFloat) -> (width: Int, height: Int) {
        let raw = CaptureConfigurationMath.pixelSize(contentRect: contentRect,
                                                     pointPixelScale: pointPixelScale)
        return (width: even(raw.width), height: even(raw.height))
    }

    private static func even(_ value: Int) -> Int { max(2, value - (value % 2)) }
}

/// What a recording is, written alongside it.
///
/// **`state` is written before the first frame arrives.** A bundle still saying `recording` on next
/// launch is one the app died in the middle of, and that is the only signal there is — a crashed
/// process leaves no error to catch, exactly as a denied Screen Recording grant leaves none.
struct RecordingManifest: Codable, Equatable {
    enum State: String, Codable, Equatable {
        case recording
        case complete
    }

    static let defaultFPS = 60

    var formatVersion = 1
    var state: State = .recording
    var source: RecordingSource
    /// The recording's own coordinate space. Every event is in it.
    var pixelSize: SizeBox
    var pointPixelScale: CGFloat = 2
    var fps: Int = defaultFPS
    /// Where on screen it came from, in global AppKit points.
    var sourceRect: RectBox?
    var displayID: UInt32?
    var startedAt = Date()
    var duration: TimeInterval = 0
    var hasMicrophone = false
    var hasSystemAudio = false
    var hasCamera = false
    /// Shown when non-zero. A stuttering file produced silently is the failure to avoid.
    var droppedFrames = 0
    /// The user's Accessibility pointer size at record time.
    ///
    /// Stored rather than applied, because our own size multiplier compounds with theirs and the
    /// result is absurd. Dividing it out needs the number the recording was made under, not the
    /// one in force whenever the project is next opened.
    var accessibilityCursorScale: Double = 1

    init(source: RecordingSource, pixelSize: CGSize, pointPixelScale: CGFloat, fps: Int) {
        self.source = source
        self.pixelSize = SizeBox(pixelSize)
        self.pointPixelScale = pointPixelScale
        self.fps = fps
    }

    var needsRecovery: Bool { state == .recording }

    /// Hand-written for the same reason `StudioProject`'s is: a missing key takes a default and
    /// never throws. A manifest is the one file that must be readable even when everything else
    /// about the recording went wrong.
    private enum Key: String, CodingKey {
        case formatVersion, state, source, pixelSize, pointPixelScale, fps
        case sourceRect, displayID, startedAt, duration
        case hasMicrophone, hasSystemAudio, hasCamera, droppedFrames, accessibilityCursorScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func read<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }
        formatVersion = read(.formatVersion, 1)
        state = read(.state, State.recording)
        source = read(.source, RecordingSource.display)
        pixelSize = read(.pixelSize, SizeBox(.zero))
        pointPixelScale = read(.pointPixelScale, 2)
        fps = read(.fps, Self.defaultFPS)
        sourceRect = try? container.decode(RectBox.self, forKey: .sourceRect)
        displayID = try? container.decode(UInt32.self, forKey: .displayID)
        startedAt = read(.startedAt, Date())
        duration = read(.duration, 0)
        hasMicrophone = read(.hasMicrophone, false)
        hasSystemAudio = read(.hasSystemAudio, false)
        hasCamera = read(.hasCamera, false)
        droppedFrames = read(.droppedFrames, 0)
        accessibilityCursorScale = read(.accessibilityCursorScale, 1)
    }
}

/// The `.sarvrec` package: a recording and everything captured alongside it.
///
/// A directory rather than a single file, because the video is hundreds of megabytes and
/// re-serialising it on every manifest update would be absurd — and because a directory the user
/// can open shows them exactly what the app is keeping.
struct RecordingBundle: Equatable {
    let root: URL

    /// HEVC, cursor-free. **The cursor is deliberately not in here**, which is the whole reason
    /// it can be redrawn sharp at any zoom afterwards.
    var screenURL: URL { root.appendingPathComponent("screen.mov") }
    var cameraURL: URL { root.appendingPathComponent("camera.mov") }
    var microphoneURL: URL { root.appendingPathComponent("mic.m4a") }
    var systemAudioURL: URL { root.appendingPathComponent("system.m4a") }
    /// Cursor path, clicks, keystrokes, flags.
    var eventsURL: URL { root.appendingPathComponent("events.json") }
    /// Per-frame content rect, for window recordings whose window moved.
    var geometryURL: URL { root.appendingPathComponent("geometry.json") }
    var manifestURL: URL { root.appendingPathComponent("manifest.json") }
    /// Bitmaps for pointers we could not recognise, deduplicated by hash.
    var cursorsDirectory: URL { root.appendingPathComponent("cursors", isDirectory: true) }

    static let fileExtension = "sarvrec"

    @discardableResult
    static func create(at url: URL) throws -> RecordingBundle {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = RecordingBundle(root: url)
        try FileManager.default.createDirectory(at: bundle.cursorsDirectory,
                                                withIntermediateDirectories: true)
        return bundle
    }

    /// Where a new recording goes: alongside the screenshots, under a name that sorts by time.
    static func defaultDirectory() -> URL {
        CaptureHistoryStore.defaultDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    func write(_ manifest: RecordingManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    func readManifest() throws -> RecordingManifest {
        try JSONDecoder().decode(RecordingManifest.self, from: Data(contentsOf: manifestURL))
    }

    func writeEvents(_ log: EventLog) throws {
        try JSONEncoder().encode(log).write(to: eventsURL, options: .atomic)
    }

    func readEvents() throws -> EventLog {
        try JSONDecoder().decode(EventLog.self, from: Data(contentsOf: eventsURL))
    }
}
