import CoreGraphics
import Foundation
import ImageIO

/// A picture composited over the recording — a logo, a screenshot, a diagram.
///
/// **Stored in the bundle, not referenced from wherever it came from.** A project that points at a
/// file on somebody's Desktop stops working the moment that file moves, and cannot be opened on
/// another Mac at all. The `.sarvrec` package already keeps everything else the recording needs;
/// this is the same rule.
///
/// Measured in fractions of the canvas, like the camera and the text, so it keeps its framing at
/// any export size.
struct MediaOverlay: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    /// The file's name inside the bundle's `media` directory.
    var asset: String
    /// Unit canvas coordinates: where it sits and how big it is.
    var rect = CGRect(x: 0.62, y: 0.06, width: 0.32, height: 0.32)
    var opacity: Double = 1
    var cornerRadiusFraction: Double = 0
    var fadeSeconds: TimeInterval = 0.2

    static let minimumDuration: TimeInterval = 0.4

    func covers(_ t: TimeInterval) -> Bool { t >= start && t < end }

    /// 0 outside, ramping at each end, `opacity` while it holds.
    func opacity(at t: TimeInterval) -> Double {
        guard covers(t) else { return 0 }
        let ramp = max(0.0001, min(fadeSeconds, (end - start) / 2))
        return opacity * min(1, max(0, min(t - start, end - t) / ramp))
    }

    /// Hand-written for the reason every other one here is: a field added later must not make an
    /// older project unreadable, which the model treats as *no* project.
    private enum Key: String, CodingKey {
        case id, start, end, asset, rect, opacity, cornerRadiusFraction, fadeSeconds
    }

    init(start: TimeInterval, end: TimeInterval, asset: String) {
        self.start = start
        self.end = end
        self.asset = asset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func read<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }
        id = read(.id, UUID())
        start = read(.start, 0)
        end = read(.end, 0)
        asset = read(.asset, "")
        rect = read(.rect, CGRect(x: 0.62, y: 0.06, width: 0.32, height: 0.32))
        opacity = read(.opacity, 1)
        cornerRadiusFraction = read(.cornerRadiusFraction, 0)
        fadeSeconds = read(.fadeSeconds, 0.2)
    }
}

/// Loads the pictures a project's overlays refer to, once each.
///
/// **Not main-actor**, because the exporter is an actor and needs the same images the canvas does —
/// and because loading a file has no business on the main thread. Guarded by a lock for the same
/// reason `RecordingWriter` is.
final class MediaStore: @unchecked Sendable {
    static let shared = MediaStore()

    private let lock = NSLock()
    private var cache: [URL: CGImage] = [:]

    /// The supported kinds, deliberately narrow: still pictures only for now. A movie overlay wants
    /// its own decoder slaved to the screen's clock, which is the camera track's pattern and a
    /// larger piece of work than this.
    static let allowedExtensions = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp"]

    func image(at url: URL) -> CGImage? {
        lock.lock()
        if let cached = cache[url] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        lock.lock()
        cache[url] = image
        lock.unlock()
        return image
    }

    /// Every picture a project needs, keyed by its asset name.
    func images(for project: StudioProject, in recording: RecordingBundle) -> [String: CGImage] {
        var result: [String: CGImage] = [:]
        for overlay in project.mediaOverlays where !overlay.asset.isEmpty {
            let url = recording.mediaDirectory.appendingPathComponent(overlay.asset)
            if let image = image(at: url) { result[overlay.asset] = image }
        }
        return result
    }
}
