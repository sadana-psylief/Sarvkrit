import CoreGraphics
import Foundation

/// The timeline's contents, as rows of items — and its geometry, as arithmetic.
///
/// **The view used to hardcode two tracks.** `clipTrack` and `zoomTrack` were hand-placed rects,
/// `preferredHeight` was a closed-form sum of exactly those two, and each had its own bespoke hit
/// test gated on its own `contains(point)`. Adding a track meant another rect, another draw method
/// and another branch in every mouse handler — so five of the project's own collections had no
/// representation at all: masks, camera segments, captions, pointer highlights, and now text.
/// "There are no layers" was a fair description of a timeline that could only show two.
///
/// Being a value rather than geometry scattered through a view, this is also testable, which the
/// hand-placed version was not.
enum TimelineLayout {

    enum RowKind: String, CaseIterable, Equatable {
        case video, media, text, camera, zoom, mask, pointer, caption

        var name: String {
            switch self {
            case .video: return "Video"
            case .media: return "Picture"
            case .text: return "Text"
            case .camera: return "Camera"
            case .zoom: return "Zoom"
            case .mask: return "Blur"
            case .pointer: return "Point"
            case .caption: return "Captions"
            }
        }

        /// The video track is always there — an edit with no clips has nothing to edit.
        var isAlwaysShown: Bool { self == .video || self == .zoom }
    }

    struct Item: Identifiable, Equatable {
        var id: UUID
        var kind: RowKind
        /// Output time, so one mapping serves every row.
        var start: TimeInterval
        var end: TimeInterval
        var label: String
        var isSelected = false
        /// Dimmed rather than solid — a disabled zoom, for instance.
        var isMuted = false
    }

    struct Row: Identifiable, Equatable {
        var kind: RowKind
        var items: [Item]
        var id: String { kind.rawValue }
    }

    // MARK: - Geometry

    struct Metrics {
        var ruler: CGFloat = 22
        var rowHeight: CGFloat = 30
        var rowGap: CGFloat = 4
        var inset: CGFloat = 12
        /// The names down the left edge, so it is obvious what each row is.
        var gutter: CGFloat = 58
        /// A grab this near an edge is a trim, not a move.
        var edgeGrab: CGFloat = 6
    }

    /// How tall the view wants to be for this many rows.
    static func preferredHeight(rowCount: Int, metrics: Metrics = Metrics()) -> CGFloat {
        let rows = max(1, rowCount)
        return metrics.ruler + CGFloat(rows) * metrics.rowHeight
            + CGFloat(max(0, rows - 1)) * metrics.rowGap + 8
    }

    static func rect(ofRow index: Int, in bounds: CGRect,
                     metrics: Metrics = Metrics()) -> CGRect {
        CGRect(x: 0,
               y: metrics.ruler + CGFloat(index) * (metrics.rowHeight + metrics.rowGap),
               width: bounds.width, height: metrics.rowHeight)
    }

    // MARK: - Contents

    /// Every row worth showing, in a fixed order so the timeline does not rearrange itself.
    static func rows(project: StudioProject, events: EventLog,
                     selection: Selection = Selection()) -> [Row] {
        let timeline = project.timeline

        /// A source range's place in the finished video, or nil if the edit cut it out entirely.
        func output(_ start: TimeInterval, _ end: TimeInterval) -> (TimeInterval, TimeInterval)? {
            guard let from = timeline.outputTime(forSource: start)
                    ?? timeline.outputTime(forSource: end) else { return nil }
            let to = timeline.outputTime(forSource: max(start, end - 0.0001)) ?? timeline.duration
            return (min(from, to), max(from, to))
        }

        var clips: [Item] = []
        var elapsed: TimeInterval = 0
        for clip in timeline.clips {
            var label = String(format: "%.1fs", clip.outputDuration)
            if clip.speed != 1 { label += String(format: " · %.2gx", clip.speed) }
            if clip.hold > 0 { label += String(format: " · hold %.1fs", clip.hold) }
            clips.append(Item(id: clip.id, kind: .video, start: elapsed,
                              end: elapsed + clip.outputDuration, label: label,
                              isSelected: selection.clip == clip.id))
            elapsed += clip.outputDuration
        }

        let media = project.mediaOverlays.compactMap { overlay -> Item? in
            guard let range = output(overlay.start, overlay.end) else { return nil }
            return Item(id: overlay.id, kind: .media, start: range.0, end: range.1,
                        label: "Picture", isSelected: selection.media == overlay.id)
        }

        let text = project.textOverlays.compactMap { overlay -> Item? in
            guard let range = output(overlay.start, overlay.end) else { return nil }
            return Item(id: overlay.id, kind: .text, start: range.0, end: range.1,
                        label: overlay.text.isEmpty ? "Text" : overlay.text,
                        isSelected: selection.text == overlay.id)
        }

        let camera = project.cameraSegments.compactMap { segment -> Item? in
            guard let range = output(segment.start, segment.end) else { return nil }
            return Item(id: segment.id, kind: .camera, start: range.0, end: range.1,
                        label: segment.layout.title, isSelected: selection.camera == segment.id)
        }

        let zooms = project.zooms.compactMap { segment -> Item? in
            guard let range = output(segment.start, segment.end) else { return nil }
            var label = String(format: "%.1fx", segment.level)
            if case .followCursor = segment.anchor { label += " · follows" }
            return Item(id: segment.id, kind: .zoom, start: range.0, end: range.1, label: label,
                        isSelected: selection.zoom == segment.id, isMuted: segment.isDisabled)
        }

        let masks = project.masks.compactMap { mask -> Item? in
            guard let range = output(mask.start, mask.end) else { return nil }
            return Item(id: mask.id, kind: .mask, start: range.0, end: range.1,
                        label: mask.mode.title, isSelected: selection.mask == mask.id)
        }

        let pointers = project.pointerHighlights.compactMap { spot -> Item? in
            guard let range = output(spot.start, spot.end) else { return nil }
            return Item(id: spot.id, kind: .pointer, start: range.0, end: range.1,
                        label: "Point", isSelected: selection.pointer == spot.id)
        }

        let captions = project.captions.compactMap { caption -> Item? in
            guard let range = output(caption.start, caption.end) else { return nil }
            return Item(id: caption.id, kind: .caption, start: range.0, end: range.1,
                        label: caption.text)
        }

        let all: [Row] = [
            Row(kind: .video, items: clips),
            Row(kind: .media, items: media),
            Row(kind: .text, items: text),
            Row(kind: .camera, items: camera),
            Row(kind: .zoom, items: zooms),
            Row(kind: .mask, items: masks),
            Row(kind: .pointer, items: pointers),
            Row(kind: .caption, items: captions),
        ]
        // An empty row is noise; a row that appears when you add the first of something is how you
        // learn the track exists.
        return all.filter { !$0.items.isEmpty || $0.kind.isAlwaysShown }
    }

    /// What is selected, in one place, so `rows` needs one parameter rather than six.
    struct Selection: Equatable {
        var clip: Clip.ID?
        var zoom: ZoomSegment.ID?
        var text: TextOverlay.ID?
        var camera: CameraSegment.ID?
        var mask: StudioMask.ID?
        var pointer: PointerHighlight.ID?
        var media: MediaOverlay.ID?
    }
}
