import AppKit
import Foundation
import QuickLookThumbnailing

/// Real previews for parked files — a PDF's first page, an image's content, a document's own icon.
///
/// Two decisions worth stating:
///
/// **Asynchronous, always.** `QLThumbnailGenerator` can take a moment on a large document, and the
/// shelf appears under a pointer that is mid-drag. A tile shows the file's plain icon immediately
/// and upgrades when the real preview lands, so nothing ever waits.
///
/// **The cache lives here, on a store-owned object, never in view state.** `ShelfController`
/// rebuilds its hosting view on every `show()` — deliberately, because a reused SwiftUI view showed
/// stale contents — so a cache held in `@State` would be thrown away every time the shelf opened.
/// `ClipboardStore` reached the same conclusion for the same reason.
@MainActor
final class ShelfThumbnails: ObservableObject {
    /// Bumped whenever a thumbnail arrives, so views re-read the cache.
    @Published private(set) var generation = 0

    private var cache: [UUID: NSImage] = [:]
    private var inFlight: Set<UUID> = []

    private let generator = QLThumbnailGenerator.shared

    /// The cached preview, kicking off generation if there isn't one yet.
    ///
    /// - Returns: the preview if ready, otherwise nil — callers show the plain icon meanwhile.
    func thumbnail(for item: ShelfItem, url: URL?, size: CGSize, scale: CGFloat) -> NSImage? {
        if let cached = cache[item.id] { return cached }
        guard let url, !inFlight.contains(item.id) else { return nil }

        inFlight.insert(item.id)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )

        generator.generateBestRepresentation(for: request) { [weak self] representation, _ in
            // The completion arrives on an internal queue, so everything below hops to main.
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(item.id)
                guard let representation else { return }
                self.cache[item.id] = NSImage(
                    cgImage: representation.cgImage,
                    size: NSSize(width: size.width, height: size.height)
                )
                self.generation &+= 1
            }
        }
        return nil
    }

    /// Dropped when its item is, so the cache can't outlive the shelf's contents.
    func forget(_ id: UUID) {
        cache.removeValue(forKey: id)
        inFlight.remove(id)
    }

    func forgetAll() {
        cache.removeAll()
        inFlight.removeAll()
    }

    /// Whether a preview is ready, without triggering generation. For tests, and for deciding
    /// whether a tile can supply its own drag image.
    func cached(_ id: UUID) -> NSImage? { cache[id] }
}
