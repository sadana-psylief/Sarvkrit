import CoreGraphics
import Foundation

/// One capture in the history.
///
/// Mirrors `ShelfItem`'s shape, but the ownership rule is **inverted and that is the whole
/// difference**. The Shelf points at the user's files and must never delete one — "referenced
/// files are never ours". Every byte here was created by us and lives in our own directory, so
/// removing an item genuinely does delete the file, and nothing needs a security-scoped bookmark.
struct CaptureHistoryItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// File name within the captures directory. Not a path: the directory can move between
    /// releases, and a stored absolute path would break every entry when it did.
    var fileName: String
    var mode: CaptureMode
    var createdAt: Date = Date()
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int
    /// Where on screen it came from, so Pin to Screen can put it back. Global AppKit points.
    var sourceRect: CGRect?
    var displayID: CGDirectDisplayID?
    /// The app that owned the window, for a window capture.
    var sourceBundleID: String?

    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    /// "1920 × 1080" — the multiplication sign, not an x.
    var dimensionText: String { "\(pixelWidth) × \(pixelHeight)" }
}
