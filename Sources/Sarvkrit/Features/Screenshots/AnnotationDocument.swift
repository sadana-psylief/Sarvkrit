import CoreGraphics
import Foundation

/// Everything about an edited capture except the pixels.
///
/// **All geometry is in image pixels, top-left origin, y increasing downward** — the `CGImage`
/// convention, not AppKit's. Said once, here, and every conversion goes through `CanvasTransform`.
/// `ScreenCoordinates` exists in this codebase because exactly this class of mistake already
/// shipped once in window management; one converter with tests is the defence.
struct AnnotationDocument: Codable, Equatable {
    /// Bumped only for a change a *reader* must understand. Additive fields don't bump it.
    var formatVersion: Int = 1
    /// Pixel dimensions of the base bitmap, not its point size.
    var imageSize: CGSize
    /// The capture's backing scale, so tool defaults are the right physical size on a Retina shot.
    var scale: CGFloat = 1
    /// Non-destructive crop.
    ///
    /// **A document property, not an element.** Elements keep absolute coordinates in the
    /// uncropped bitmap, so uncropping restores annotations that were outside the frame — where
    /// rewriting every element's origin on crop would have destroyed them.
    var cropRect: CGRect?
    /// The background composite, applied after flattening. Nil means none.
    var background: CaptureBackground?
    var elements: [AnnotationElement] = []

    init(imageSize: CGSize, scale: CGFloat = 1) {
        self.imageSize = imageSize
        self.scale = scale
    }

    // MARK: - Coding

    private enum Keys: String, CodingKey {
        case formatVersion, imageSize, scale, cropRect, background, elements
    }

    /// Written by hand so a **missing** key takes the property's default.
    ///
    /// Swift's synthesised decoder does not do this — it throws `keyNotFound` even when the
    /// property has a default value, which was verified by a test here rather than assumed. Without
    /// this, adding any field would make every previously-saved document unopenable, and the claim
    /// that additive changes don't need a format bump would be false.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        imageSize = try container.decode(CGSize.self, forKey: .imageSize)
        scale = try container.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
        cropRect = try container.decodeIfPresent(CGRect.self, forKey: .cropRect)
        background = try container.decodeIfPresent(CaptureBackground.self, forKey: .background)
        elements = try container.decodeIfPresent([AnnotationElement].self, forKey: .elements) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(imageSize, forKey: .imageSize)
        try container.encode(scale, forKey: .scale)
        try container.encodeIfPresent(cropRect, forKey: .cropRect)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encode(elements, forKey: .elements)
    }

    // MARK: - Elements

    /// Elements in draw order, unknown ones excluded — they are carried, not rendered.
    var drawable: [AnnotationElement] {
        elements.filter { !$0.isUnknown }.sorted { $0.z < $1.z }
    }

    var unknownCount: Int { elements.filter(\.isUnknown).count }

    mutating func add(_ kind: AnnotationElement.Kind) {
        let next = (elements.map(\.z).max() ?? -1) + 1
        elements.append(AnnotationElement(z: next, kind: kind))
        renumberCounters()
    }

    mutating func remove(id: AnnotationElement.ID) {
        elements.removeAll { $0.id == id }
        renumberCounters()
    }

    mutating func bringToFront(id: AnnotationElement.ID) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[index].z = (elements.map(\.z).max() ?? 0) + 1
    }

    mutating func sendToBack(id: AnnotationElement.ID) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[index].z = (elements.map(\.z).min() ?? 0) - 1
    }

    /// Numbers the counters 1…n in draw order.
    ///
    /// **Draw order, not insertion order**, so a counter moved behind another renumbers to match
    /// what the reader sees. Deleting the second of four renumbers the rest, which is the whole
    /// point of a counter tool — a tutorial that jumps from 1 to 3 is a broken tutorial.
    mutating func renumberCounters() {
        var next = 1
        for index in elements.indices.sorted(by: { elements[$0].z < elements[$1].z }) {
            guard case .counter(var counter) = elements[index].kind else { continue }
            counter.number = next
            elements[index].kind = .counter(counter)
            next += 1
        }
    }

    /// The rect the finished image occupies, honouring a crop.
    var contentRect: CGRect {
        cropRect ?? CGRect(origin: .zero, size: imageSize)
    }
}
