import CoreGraphics
import CoreImage
import Foundation

/// What a frame needs from outside itself.
///
/// Resolved by the caller and handed in — the same contract `BackgroundCompositor.Sources` uses,
/// and for the same reason: a renderer that reaches into a store is a renderer that cannot be
/// tested with a bitmap, and the export path is not on the main actor.
struct FrameSources {
    /// The decoded screen frame at this instant. Nil renders the surround alone, which is what a
    /// scrub past the end of the recording should show rather than black.
    var screen: CGImage?
    var camera: CGImage?
    var wallpaper: CGImage?
    /// Bitmaps for pointers that could not be recognised, keyed by hash.
    var customCursors: [String: CGImage] = [:]

    init(screen: CGImage? = nil, camera: CGImage? = nil, wallpaper: CGImage? = nil,
         customCursors: [String: CGImage] = [:]) {
        self.screen = screen
        self.camera = camera
        self.wallpaper = wallpaper
        self.customCursors = customCursors
    }
}

/// Compositing one frame of a project.
///
/// **One function, called by both the preview and the export.** If they can diverge they will, and
/// every "the export doesn't match what I saw" bug lives in that gap — so there is no separate
/// preview path. `AnnotationRenderer` already establishes the pattern on the screenshot side.
///
/// The layer order is stated once, here, because every feature plugs into a named slot:
/// **background → screen shadow → screen → click effect → cursor → camera → captions.**
enum StudioRenderer {

    /// Everything that does not change between frames, worked out once.
    ///
    /// **The whole performance strategy is finding what does not change and not redrawing it.** A
    /// mesh gradient at canvas resolution is far too slow to paint sixty times a second and does
    /// not need to be: it is the same picture every frame.
    final class Cache {
        fileprivate var backgroundKey: String?
        fileprivate var background: CGImage?
        fileprivate var canvasSize: CGSize = .zero
        init() {}
    }

    /// The finished canvas size and where the recording sits inside it.
    ///
    /// Reuses `BackgroundLayout` untouched — the arithmetic for padding, an aspect target and
    /// alignment is identical for a video and a screenshot, and it is already tested.
    static func layout(for project: StudioProject) -> (canvas: CGSize, imageRect: CGRect) {
        var style = project.background
        style.aspect = project.aspect
        let source = project.cropRect?.size ?? project.canvasSize
        return BackgroundLayout.compute(imageSize: source, style: style)
    }

    /// The frame at `sourceTime`, in the recording's own clock.
    static func frame(of project: StudioProject,
                      atSource sourceTime: TimeInterval,
                      events: EventLog,
                      sources: FrameSources,
                      cache: Cache = Cache()) -> CGImage? {
        let (canvas, imageRect) = layout(for: project)
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }

        guard let context = CGContext(
            data: nil, width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Document space: top-left origin, so `imageRect` means what it says. Same flip the
        // annotation renderer and the background compositor both use.
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)

        draw(project: project, sourceTime: sourceTime, events: events, sources: sources,
             canvas: canvas, imageRect: imageRect, in: context, cache: cache)

        return context.makeImage()
    }

    static func draw(project: StudioProject,
                     sourceTime: TimeInterval,
                     events: EventLog,
                     sources: FrameSources,
                     canvas: CGSize,
                     imageRect: CGRect,
                     in context: CGContext,
                     cache: Cache) {

        // 1 — background. Cached: it is the same picture every frame.
        drawBackground(project: project, canvas: canvas, sources: sources,
                       in: context, cache: cache)

        // 2 and 3 — the screen, with its shadow underneath following the corner radius rather than
        // the bitmap's square edges.
        var style = project.background
        style.aspect = project.aspect
        BackgroundCompositor.drawSurround(style: style,
                                          canvas: CGRect(origin: .zero, size: canvas),
                                          imageRect: imageRect, in: context,
                                          sources: .init(base: sources.screen,
                                                         wallpaper: sources.wallpaper))

        let transform = ZoomResolver.transform(
            at: sourceTime,
            segments: project.visibleZooms,
            cursor: events.isCursorInside(at: sourceTime) ? events.cursorPoint(at: sourceTime) : nil,
            frameSize: project.canvasSize)

        context.saveGState()
        context.addPath(BackgroundCompositor.clipPath(imageRect: imageRect, style: style))
        context.clip()
        drawScreen(project: project, transform: transform, imageRect: imageRect,
                   sources: sources, in: context)

        // 4 and 5 — click effect and cursor, both inside the screen's clip so a pointer near the
        // edge is cut by the rounded corner exactly as the content is.
        drawClicks(project: project, sourceTime: sourceTime, events: events,
                   transform: transform, imageRect: imageRect, in: context)
        drawCursor(project: project, sourceTime: sourceTime, events: events,
                   transform: transform, imageRect: imageRect, sources: sources, in: context)
        context.restoreGState()

        // 6 and 7 — camera and captions, in canvas space: they belong to the finished video, not
        // to the recording, so a zoom must not move them.
        drawCaptions(project: project, sourceTime: sourceTime, canvas: canvas, in: context)
    }

    // MARK: - Background

    private static func drawBackground(project: StudioProject, canvas: CGSize,
                                       sources: FrameSources, in context: CGContext,
                                       cache: Cache) {
        let key = backgroundKey(project.background, canvas: canvas)
        if cache.backgroundKey == key, let cached = cache.background, cache.canvasSize == canvas {
            context.drawFlipped(cached, in: CGRect(origin: .zero, size: canvas))
            return
        }

        guard let scratch = CGContext(
            data: nil, width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        BackgroundCompositor.drawFill(project.background.fill,
                                      in: CGRect(origin: .zero, size: canvas),
                                      context: scratch,
                                      sources: .init(base: sources.screen,
                                                     wallpaper: sources.wallpaper))
        guard let image = scratch.makeImage() else { return }
        cache.background = image
        cache.backgroundKey = key
        cache.canvasSize = canvas
        context.drawFlipped(image, in: CGRect(origin: .zero, size: canvas))
    }

    /// A blurred fill is derived from the capture and therefore changes with it; everything else is
    /// a description and can be keyed by its own value.
    private static func backgroundKey(_ background: CaptureBackground, canvas: CGSize) -> String {
        if case .blurred = background.fill { return "blurred-\(canvas)-\(UUID().uuidString)" }
        let data = try? JSONEncoder().encode(background.fill)
        return "\(canvas)-\(data?.hashValue ?? 0)"
    }

    // MARK: - Screen

    private static func drawScreen(project: StudioProject, transform: ZoomTransform,
                                   imageRect: CGRect, sources: FrameSources,
                                   in context: CGContext) {
        guard let screen = sources.screen else { return }

        // The crop is applied first and the zoom on top of it, so a project that was cropped and
        // then zoomed frames what the user saw when they set the zoom.
        let full = CGRect(origin: .zero, size: project.canvasSize)
        let cropped = project.cropRect ?? full
        let visible = ZoomResolver.sourceRect(for: transform, frameSize: cropped.size)
        let source = CGRect(x: cropped.minX + visible.minX, y: cropped.minY + visible.minY,
                            width: visible.width, height: visible.height)

        guard let piece = screen.cropping(to: source.integral) ?? screen.cropping(to: full) else {
            return
        }
        context.saveGState()
        context.interpolationQuality = .high
        context.drawFlipped(piece, in: imageRect)
        context.restoreGState()
    }

    // MARK: - Cursor

    private static func drawCursor(project: StudioProject, sourceTime: TimeInterval,
                                   events: EventLog, transform: ZoomTransform,
                                   imageRect: CGRect, sources: FrameSources,
                                   in context: CGContext) {
        let settings = project.cursor
        guard !settings.isHidden,
              events.isCursorInside(at: sourceTime),
              let point = events.cursorPoint(at: sourceTime) else { return }

        let opacity = idleOpacity(settings: settings, events: events, at: sourceTime)
        guard opacity > 0.01 else { return }

        guard let placed = canvasPoint(point, project: project, transform: transform,
                                       imageRect: imageRect) else { return }

        let kind = events.cursorKind(at: sourceTime)
        let height = CursorGlyph.drawnSize(base: settings.size, zoom: transform.scale)
        let scaled = CGFloat(height) * imageRect.width / max(project.canvasSize.width, 1)
            * CGFloat(transform.scale)

        let click = lastClick(events: events, at: sourceTime)
        let effect = click.map {
            ClickEffect.state(settings.clickEffect, secondsSinceClick: sourceTime - $0.t)
        } ?? nil
        let drawn = scaled * CGFloat(effect?.cursorScale ?? 1)

        context.saveGState()
        context.setAlpha(CGFloat(opacity))
        if kind == .custom, let hash = events.customCursorHash(at: sourceTime),
           let bitmap = sources.customCursors[hash] {
            // An unrecognised pointer keeps its own bitmap. Drawing an arrow where a brush was is
            // worse than a slightly soft cursor, and a design tool is exactly what people record.
            let aspect = CGFloat(bitmap.width) / CGFloat(max(bitmap.height, 1))
            context.drawFlipped(bitmap, in: CGRect(x: placed.x, y: placed.y,
                                                   width: drawn * aspect, height: drawn))
        } else if let rendered = CursorGlyph.rendered(for: kind,
                                                      glyphHeight: max(8, Int(drawn.rounded()))) {
            // The bitmap is larger than the glyph because the shadow needs room, so it is scaled
            // by the same ratio and offset by the inset rather than treated as the pointer itself.
            let ratio = CGFloat(rendered.image.height) / max(rendered.glyphHeight, 1)
            let insetFraction = rendered.inset / max(rendered.glyphHeight, 1)
            let origin = CursorGlyph.origin(for: kind, at: placed, drawnHeight: drawn,
                                            insetFraction: insetFraction)
            context.drawFlipped(rendered.image, in: CGRect(x: origin.x, y: origin.y,
                                                           width: drawn * ratio,
                                                           height: drawn * ratio))
        }
        context.restoreGState()
    }

    /// Fades the pointer out once it has been still, and back in the moment it moves.
    ///
    /// This is what stops a recording that pauses on a diagram having a pointer sitting in the
    /// middle of it for thirty seconds.
    private static func idleOpacity(settings: CursorSettings, events: EventLog,
                                    at t: TimeInterval) -> Double {
        guard settings.hidesWhenIdle, let current = events.cursorPoint(at: t) else { return 1 }
        var still: TimeInterval = 0
        var probe = t
        while probe > 0, still < settings.idleDelay + 1 {
            probe -= 0.1
            guard let earlier = events.cursorPoint(at: probe),
                  hypot(earlier.x - current.x, earlier.y - current.y) < 2 else { break }
            still += 0.1
        }
        guard still >= settings.idleDelay else { return 1 }
        let fade = min(1, (still - settings.idleDelay) / 0.4)
        return 1 - fade
    }

    private static func lastClick(events: EventLog, at t: TimeInterval) -> ClickEvent? {
        events.pressDowns.last { $0.t <= t && t - $0.t <= ClickEffect.duration }
    }

    // MARK: - Clicks

    private static func drawClicks(project: StudioProject, sourceTime: TimeInterval,
                                   events: EventLog, transform: ZoomTransform,
                                   imageRect: CGRect, in context: CGContext) {
        guard let click = lastClick(events: events, at: sourceTime), click.isInside,
              let state = ClickEffect.state(project.cursor.clickEffect,
                                            secondsSinceClick: sourceTime - click.t),
              let placed = canvasPoint(click.point, project: project, transform: transform,
                                       imageRect: imageRect) else { return }

        let unit = CGFloat(CursorGlyph.drawnSize(base: project.cursor.size, zoom: transform.scale))
            * imageRect.width / max(project.canvasSize.width, 1) * CGFloat(transform.scale)
        let tint: CGColor = click.button == .right
            ? CGColor(red: 1, green: 0.62, blue: 0.24, alpha: 1)
            : CGColor(red: 0.29, green: 0.56, blue: 1, alpha: 1)

        context.saveGState()
        if state.fillAlpha > 0 {
            let radius = unit * CGFloat(state.ringRadius)
            context.setFillColor(tint.copy(alpha: CGFloat(state.fillAlpha)) ?? tint)
            context.fillEllipse(in: CGRect(x: placed.x - radius, y: placed.y - radius,
                                           width: radius * 2, height: radius * 2))
        }
        if state.ringAlpha > 0 {
            let radius = unit * CGFloat(state.ringRadius)
            context.setStrokeColor(tint.copy(alpha: CGFloat(state.ringAlpha)) ?? tint)
            context.setLineWidth(max(1, unit * 0.12))
            context.strokeEllipse(in: CGRect(x: placed.x - radius, y: placed.y - radius,
                                             width: radius * 2, height: radius * 2))
        }
        context.restoreGState()
    }

    /// Recording pixels to canvas points, through the crop and the zoom.
    ///
    /// Nil when the point is not currently visible — which happens constantly once a zoom is on,
    /// and drawing a cursor clamped to the frame edge instead would look like a bug.
    private static func canvasPoint(_ point: CGPoint, project: StudioProject,
                                    transform: ZoomTransform, imageRect: CGRect) -> CGPoint? {
        let cropped = project.cropRect ?? CGRect(origin: .zero, size: project.canvasSize)
        let visible = ZoomResolver.sourceRect(for: transform, frameSize: cropped.size)
        let local = CGPoint(x: point.x - cropped.minX - visible.minX,
                            y: point.y - cropped.minY - visible.minY)
        guard visible.width > 0, visible.height > 0,
              local.x >= 0, local.y >= 0,
              local.x <= visible.width, local.y <= visible.height else { return nil }
        return CGPoint(x: imageRect.minX + local.x / visible.width * imageRect.width,
                       y: imageRect.minY + local.y / visible.height * imageRect.height)
    }

    // MARK: - Captions

    private static func drawCaptions(project: StudioProject, sourceTime: TimeInterval,
                                     canvas: CGSize, in context: CGContext) {
        guard let caption = project.captions.first(where: {
            sourceTime >= $0.start && sourceTime <= $0.end
        }) else { return }
        CaptionRenderer.draw(caption, spokenWords: caption.spokenWordCount(at: sourceTime),
                             canvas: canvas, style: project.captionStyle, in: context)
    }
}
