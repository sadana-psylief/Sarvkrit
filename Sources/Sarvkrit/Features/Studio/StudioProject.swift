import CoreGraphics
import Foundation

/// The edit: everything the user decided, and nothing the recorder captured.
///
/// A project is small — geometry, numbers and a little text — which is what makes snapshot undo
/// through `UndoStack` cheap and autosave through `CoalescingSaver` unremarkable. The recording
/// itself lives beside it in the bundle and is never rewritten.
///
/// **Nothing here is destructive.** Trims are windows, zooms are overlays, the background is a
/// description. Deleting every value in this struct would give back the raw recording untouched.
struct StudioProject: Codable, Equatable {

    var formatVersion = 1
    /// Pixel size of the recording, which is also the coordinate space every event is in.
    var canvasSize: CGSize
    var timeline: Timeline

    /// Reused wholesale from the screenshot editor: mesh and gradient fills, padding, corner
    /// radius, the two-layer shadow, inset and alignment. A recording wants exactly the same
    /// surround a screenshot does, and the code for it is written and tested.
    var background = CaptureBackground()
    var aspect: AspectRatio = .original
    var cropRect: CGRect?

    var zooms: [ZoomSegment] = []
    var cursor = CursorSettings()
    var captions: [Caption] = []
    var captionStyle = CaptionStyle()
    var masks: [StudioMask] = []
    var camera = CameraSettings()
    var cameraSegments: [CameraSegment] = []
    /// Clicks added or taken out by hand. The recording itself is never touched.
    var clickEdits = ClickEdits()
    /// Stretches where the pointer's surroundings are dimmed, to say "look here".
    var pointerHighlights: [PointerHighlight] = []
    /// Text put on the video by hand. Distinct from `captions`, which come from transcription.
    var textOverlays: [TextOverlay] = []
    /// Seconds of black the video fades up from, and down to.
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0
    var keystrokes = KeystrokeSettings()
    var deviceFrame = DeviceFrameSelection()
    /// Shown in the editor, never rendered into the video.
    var speakerNotes = ""

    /// Fields written by a newer build.
    ///
    /// Held verbatim and written back unchanged, so opening a project in an older build and saving
    /// it does not quietly delete work done in a newer one. A recording is hundreds of megabytes of
    /// somebody's afternoon; silently dropping part of the edit is not an acceptable way to fail.
    private(set) var unrecognised: [String: JSONValue] = [:]

    init(canvasSize: CGSize, timeline: Timeline) {
        self.canvasSize = canvasSize
        self.timeline = timeline
    }

    // MARK: - Derived

    var duration: TimeInterval { timeline.duration }

    /// The zooms that still have a moment to happen in.
    ///
    /// A segment whose source time was cut out of the edit has nowhere to be drawn. Answering that
    /// here rather than in the renderer means the question is asked once per edit instead of sixty
    /// times a second.
    var visibleZooms: [ZoomSegment] {
        zooms.filter { segment in
            guard !segment.isDisabled else { return false }
            return timeline.outputTime(forSource: segment.start) != nil
                || timeline.outputTime(forSource: segment.end) != nil
        }
    }

    // MARK: - Coding

    /// Hand-written, and the shape is the same one `AnnotationDocument` uses: **a missing key takes
    /// a default, it never throws.** A project saved before a field existed has to open cleanly
    /// rather than resetting everything the user had set.
    private enum Key: String, CaseIterable {
        case formatVersion, canvasSize, timeline, background, aspect, cropRect
        case zooms, cursor, captions, captionStyle, speakerNotes
        case masks, camera, cameraSegments, keystrokes, deviceFrame
        case clickEdits, pointerHighlights, textOverlays, fadeIn, fadeOut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StudioCodingKey.self)

        func read<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: StudioCodingKey(key.rawValue))) ?? fallback
        }

        formatVersion = read(.formatVersion, 1)
        canvasSize = read(.canvasSize, SizeBox(.zero)).size
        timeline = read(.timeline, Timeline(clips: []))
        background = read(.background, CaptureBackground())
        aspect = read(.aspect, AspectRatio.original)
        cropRect = (try? container.decode(RectBox.self,
                                          forKey: StudioCodingKey(Key.cropRect.rawValue)))?.rect
        zooms = read(.zooms, [ZoomSegment]())
        cursor = read(.cursor, CursorSettings())
        captions = read(.captions, [Caption]())
        captionStyle = read(.captionStyle, CaptionStyle())
        masks = read(.masks, [StudioMask]())
        camera = read(.camera, CameraSettings())
        cameraSegments = read(.cameraSegments, [CameraSegment]())
        clickEdits = read(.clickEdits, ClickEdits())
        pointerHighlights = read(.pointerHighlights, [PointerHighlight]())
        textOverlays = read(.textOverlays, [TextOverlay]())
        fadeIn = read(.fadeIn, 0)
        fadeOut = read(.fadeOut, 0)
        keystrokes = read(.keystrokes, KeystrokeSettings())
        deviceFrame = read(.deviceFrame, DeviceFrameSelection())
        speakerNotes = read(.speakerNotes, "")

        let known = Set(Key.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try? container.decode(JSONValue.self, forKey: key)
        }
        unrecognised = extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StudioCodingKey.self)
        try container.encode(formatVersion, forKey: StudioCodingKey(Key.formatVersion.rawValue))
        try container.encode(SizeBox(canvasSize), forKey: StudioCodingKey(Key.canvasSize.rawValue))
        try container.encode(timeline, forKey: StudioCodingKey(Key.timeline.rawValue))
        try container.encode(background, forKey: StudioCodingKey(Key.background.rawValue))
        try container.encode(aspect, forKey: StudioCodingKey(Key.aspect.rawValue))
        try container.encodeIfPresent(cropRect.map(RectBox.init),
                                      forKey: StudioCodingKey(Key.cropRect.rawValue))
        try container.encode(zooms, forKey: StudioCodingKey(Key.zooms.rawValue))
        try container.encode(cursor, forKey: StudioCodingKey(Key.cursor.rawValue))
        try container.encode(captions, forKey: StudioCodingKey(Key.captions.rawValue))
        try container.encode(captionStyle, forKey: StudioCodingKey(Key.captionStyle.rawValue))
        try container.encode(masks, forKey: StudioCodingKey(Key.masks.rawValue))
        try container.encode(camera, forKey: StudioCodingKey(Key.camera.rawValue))
        try container.encode(cameraSegments, forKey: StudioCodingKey(Key.cameraSegments.rawValue))
        try container.encode(clickEdits, forKey: StudioCodingKey(Key.clickEdits.rawValue))
        try container.encode(pointerHighlights,
                             forKey: StudioCodingKey(Key.pointerHighlights.rawValue))
        try container.encode(textOverlays, forKey: StudioCodingKey(Key.textOverlays.rawValue))
        try container.encode(fadeIn, forKey: StudioCodingKey(Key.fadeIn.rawValue))
        try container.encode(fadeOut, forKey: StudioCodingKey(Key.fadeOut.rawValue))
        try container.encode(keystrokes, forKey: StudioCodingKey(Key.keystrokes.rawValue))
        try container.encode(deviceFrame, forKey: StudioCodingKey(Key.deviceFrame.rawValue))
        try container.encode(speakerNotes, forKey: StudioCodingKey(Key.speakerNotes.rawValue))

        // Written back last and untouched. Anything this build added under the same name would be
        // overwritten by its own key above, which is correct: a field we now understand is ours.
        for (name, value) in unrecognised {
            try container.encode(value, forKey: StudioCodingKey(name))
        }
    }
}

/// `CGSize` and `CGRect` written as named fields rather than as arrays.
///
/// **Their synthesised `Codable` encodes a bare `[1920, 1080]`.** That round-trips perfectly well
/// and is unreadable: the project bundle is a package the user can open, and a file that says
/// `"canvasSize": [2560, 1440]` tells them nothing about which number is which. Two extra words in
/// the file is the whole cost.
struct SizeBox: Codable, Equatable {
    var width: CGFloat
    var height: CGFloat

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    var size: CGSize { CGSize(width: width, height: height) }
}

struct RectBox: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
