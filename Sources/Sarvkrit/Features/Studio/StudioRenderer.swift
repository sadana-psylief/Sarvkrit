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
    /// Pictures the user brought in, keyed by asset name.
    var media: [String: CGImage] = [:]

    init(screen: CGImage? = nil, camera: CGImage? = nil, wallpaper: CGImage? = nil,
         customCursors: [String: CGImage] = [:], media: [String: CGImage] = [:]) {
        self.screen = screen
        self.camera = camera
        self.wallpaper = wallpaper
        self.customCursors = customCursors
        self.media = media
    }

    /// The wallpaper a project's background needs, if any.
    ///
    /// **One definition, used by the live canvas and the export both.** The screenshot editor
    /// states why next to its own equivalent: the two disagreeing about a background is a failure
    /// that feature has already had once, with the surround visible in the file and not on the
    /// canvas. Studio managed the opposite of both — it passed no wallpaper anywhere, so a
    /// wallpaper background simply rendered as nothing.
    /// Main-actor because `WallpaperStore` is; resolved once, before any render loop.
    @MainActor
    static func wallpaper(for project: StudioProject) -> CGImage? {
        guard case .image(let fileName) = project.background.fill else { return nil }
        return WallpaperStore.shared.image(named: fileName)
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
                      cache: Cache = Cache(),
                      clipSource: Range<TimeInterval>? = nil,
                      outputTime: TimeInterval? = nil) -> CGImage? {
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
             canvas: canvas, imageRect: imageRect, in: context, cache: cache,
             clipSource: clipSource, outputTime: outputTime)

        return context.makeImage()
    }

    static func draw(project: StudioProject,
                     sourceTime: TimeInterval,
                     events: EventLog,
                     sources: FrameSources,
                     canvas: CGSize,
                     imageRect: CGRect,
                     in context: CGContext,
                     cache: Cache,
                     clipSource: Range<TimeInterval>? = nil,
                     /// The moment in the *finished* video, which the fades and dips are placed in.
                     outputTime: TimeInterval? = nil) {

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

        // A device frame insets the recording rather than growing the canvas, so turning it on
        // does not change how much of the picture is visible.
        let frame = DeviceFrameRenderer.layout(project.deviceFrame, imageRect: imageRect)
        if let frame { DeviceFrameRenderer.drawBody(frame, in: context) }
        let screenRect = frame?.screenRect ?? imageRect

        let transform = ZoomResolver.transform(
            at: sourceTime,
            segments: project.visibleZooms,
            cursor: events.isCursorInside(at: sourceTime) ? events.cursorPoint(at: sourceTime) : nil,
            frameSize: project.canvasSize,
            clipSource: clipSource)

        context.saveGState()
        if let frame {
            context.addPath(frame.screen)
        } else {
            context.addPath(BackgroundCompositor.clipPath(imageRect: screenRect, style: style))
        }
        context.clip()
        drawScreen(project: project, transform: transform, imageRect: screenRect,
                   sources: sources, in: context)

        // 4 and 5 — click effect and cursor, both inside the screen's clip so a pointer near the
        // edge is cut by the rounded corner exactly as the content is.
        drawMasks(project: project, sourceTime: sourceTime, transform: transform,
                  imageRect: screenRect, screen: sources.screen, in: context)
        drawPointerSpotlight(project: project, sourceTime: sourceTime, events: events,
                             transform: transform, imageRect: screenRect, in: context)
        drawClicks(project: project, sourceTime: sourceTime, events: events,
                   transform: transform, imageRect: screenRect, in: context)
        drawCursor(project: project, sourceTime: sourceTime, events: events,
                   transform: transform, imageRect: screenRect, sources: sources, in: context)
        context.restoreGState()

        if let frame { DeviceFrameRenderer.drawRim(frame, in: context) }

        // 6 and 7 — camera and captions, in canvas space: they belong to the finished video, not
        // to the recording, so a zoom must not move them.
        drawCamera(project: project, sourceTime: sourceTime, transform: transform,
                   canvas: canvas, camera: sources.camera, in: context,
                   clipSource: clipSource)
        drawKeystrokes(project: project, sourceTime: sourceTime, events: events,
                       canvas: canvas, in: context)
        drawCaptions(project: project, sourceTime: sourceTime, canvas: canvas, in: context)
        // Last, so hand-placed text sits above everything including the camera — which is what
        // somebody putting a title on a frame expects.
        // Pictures below text, so a caption over a logo stays readable.
        drawMediaOverlays(project: project, sourceTime: sourceTime, canvas: canvas,
                          media: sources.media, in: context)
        drawTextOverlays(project: project, sourceTime: sourceTime, canvas: canvas, in: context)

        // **Last of all, over everything.** A fade to black that left the titles showing would not
        // be a fade to black.
        if let outputTime {
            let alpha = FadeCurtain.alpha(atOutput: outputTime, duration: project.duration,
                                          fadeIn: project.fadeIn, fadeOut: project.fadeOut,
                                          dips: FadeCurtain.dips(in: project.timeline))
            if alpha > 0.001 {
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(alpha)))
                context.fill(CGRect(origin: .zero, size: canvas))
            }
        }
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

        let click = lastClick(project: project, events: events, at: sourceTime)
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

    private static func lastClick(project: StudioProject, events: EventLog,
                                  at t: TimeInterval) -> ClickEvent? {
        // The ordinary case allocates nothing it did not before: with no edits this is exactly the
        // recording's own presses. `ClickTrack` only gets involved once somebody has changed
        // something, and even then it never modifies the recording.
        guard project.clickEdits != ClickEdits() else {
            return events.pressDowns.last { $0.t <= t && t - $0.t <= ClickEffect.duration }
        }
        return ClickTrack.effective(recorded: events.clicks, edits: project.clickEdits)
            .last { $0.t <= t && t - $0.t <= ClickEffect.duration }
    }

    // MARK: - Clicks

    private static func drawClicks(project: StudioProject, sourceTime: TimeInterval,
                                   events: EventLog, transform: ZoomTransform,
                                   imageRect: CGRect, in context: CGContext) {
        guard let click = lastClick(project: project, events: events, at: sourceTime),
              click.isInside,
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

    /// Where each visible line of hand-placed text sits, in canvas points.
    ///
    /// Shared with the canvas so dragging text hits exactly what is drawn, rather than a second
    /// guess at the same geometry — the class of bug the wallpaper helper exists to avoid.
    static func textBoxes(project: StudioProject, sourceTime: TimeInterval,
                          canvas: CGSize) -> [(id: TextOverlay.ID, rect: CGRect)] {
        guard canvas.height > 0 else { return [] }
        return project.textOverlays.compactMap { overlay in
            guard overlay.covers(sourceTime), !overlay.text.isEmpty else { return nil }
            let style = TextLayer.Style(
                font: overlay.font(forCanvasHeight: canvas.height),
                colour: overlay.colour,
                background: overlay.background,
                padding: canvas.height * CGFloat(overlay.paddingFraction),
                cornerRadius: canvas.height * CGFloat(overlay.cornerRadiusFraction),
                haloColour: overlay.haloColour)
            let rect = TextLayer.box(
                for: overlay.text,
                centredOn: CGPoint(x: canvas.width * overlay.origin.x,
                                   y: canvas.height * overlay.origin.y),
                maxWidth: canvas.width * CGFloat(overlay.maxWidthFraction),
                style: style)
            return (overlay.id, rect)
        }
    }

    /// Pictures the user brought in, in canvas space — they belong to the finished video, so a
    /// zoom must not move them.
    static func drawMediaOverlays(project: StudioProject, sourceTime: TimeInterval,
                                  canvas: CGSize, media: [String: CGImage],
                                  in context: CGContext) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        for overlay in project.mediaOverlays {
            let opacity = overlay.opacity(at: sourceTime)
            guard opacity > 0.001, let image = media[overlay.asset] else { continue }

            let box = CGRect(x: canvas.width * overlay.rect.minX,
                             y: canvas.height * overlay.rect.minY,
                             width: canvas.width * overlay.rect.width,
                             height: canvas.height * overlay.rect.height)
            guard box.width > 1, box.height > 1 else { continue }

            context.saveGState()
            context.setAlpha(CGFloat(opacity))
            if overlay.cornerRadiusFraction > 0 {
                let radius = min(box.width, box.height) * CGFloat(overlay.cornerRadiusFraction)
                context.addPath(CGPath.rounded(box, cornerRadius: radius))
                context.clip()
            }
            // **Fit, not fill.** A logo that has been cropped to a square box is worse than one
            // with space around it, and stretching it is worse than either — so the picture is
            // scaled to fit inside the box and centred there.
            let source = CGSize(width: image.width, height: image.height)
            let scale = min(box.width / max(1, source.width), box.height / max(1, source.height))
            let drawn = CGSize(width: source.width * scale, height: source.height * scale)
            context.drawFlipped(image, in: CGRect(
                x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2,
                width: drawn.width, height: drawn.height))
            context.restoreGState()
        }
    }

    /// Hand-placed text, in canvas space — it belongs to the finished video rather than to the
    /// recording, like the camera and the captions, so a zoom must not move it.
    static func drawTextOverlays(project: StudioProject, sourceTime: TimeInterval,
                                 canvas: CGSize, in context: CGContext) {
        guard canvas.height > 0 else { return }
        for overlay in project.textOverlays {
            let opacity = overlay.opacity(at: sourceTime)
            guard opacity > 0.001, !overlay.text.isEmpty else { continue }
            let style = TextLayer.Style(
                font: overlay.font(forCanvasHeight: canvas.height),
                colour: overlay.colour,
                background: overlay.background,
                padding: canvas.height * CGFloat(overlay.paddingFraction),
                cornerRadius: canvas.height * CGFloat(overlay.cornerRadiusFraction),
                haloColour: overlay.haloColour,
                opacity: opacity)
            TextLayer.draw(overlay.text,
                           centredOn: CGPoint(x: canvas.width * overlay.origin.x,
                                              y: canvas.height * overlay.origin.y),
                           maxWidth: canvas.width * CGFloat(overlay.maxWidthFraction),
                           style: style, in: context)
        }
    }

    private static func drawCaptions(project: StudioProject, sourceTime: TimeInterval,
                                     canvas: CGSize, in context: CGContext) {
        guard let caption = project.captions.first(where: {
            sourceTime >= $0.start && sourceTime <= $0.end
        }) else { return }
        CaptionRenderer.draw(caption, spokenWords: caption.spokenWordCount(at: sourceTime),
                             canvas: canvas, style: project.captionStyle, in: context)
    }
}

// MARK: - The remaining layers

extension StudioRenderer {

    /// Masks, drawn inside the screen's clip so they move with the zoom exactly as the content
    /// they are hiding does.
    ///
    /// **The safe direction is opaque.** A mask that fails to resolve — its window gone, its
    /// filter unavailable — falls back to a solid fill rather than to nothing, because the one
    /// outcome that must never happen is uncovering what it was hiding.
    /// The pointer spotlight: everything outside a circle on the pointer is dimmed.
    ///
    /// **Drawn before the click effect and the cursor, and inside the screen's clip.** That order is
    /// the point — the wash dims the content being demonstrated while the pointer itself, and any
    /// click ring around it, draw on top and stay bright.
    ///
    /// One even-odd fill, exactly like a `.highlight` mask, so the two read as one idea and no two
    /// washes can darken each other.
    static func drawPointerSpotlight(project: StudioProject, sourceTime: TimeInterval,
                                     events: EventLog, transform: ZoomTransform,
                                     imageRect: CGRect, in context: CGContext) {
        let cursor = events.isCursorInside(at: sourceTime)
            ? events.cursorPoint(at: sourceTime) : nil
        guard let state = PointerSpotlight.state(at: sourceTime,
                                                 highlights: project.pointerHighlights,
                                                 cursor: cursor,
                                                 frameSize: project.canvasSize),
              state.dimming > 0.001,
              let centre = canvasPoint(state.centre, project: project, transform: transform,
                                       imageRect: imageRect) else { return }

        // Scaled with the picture, so the spotlight covers the same content zoomed in as out.
        let scale = imageRect.width / max(project.canvasSize.width, 1) * CGFloat(transform.scale)
        let radius = state.radius * scale

        let path = CGMutablePath()
        path.addRect(imageRect)
        path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                   width: radius * 2, height: radius * 2))
        context.saveGState()
        context.addPath(path)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(state.dimming)))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    static func drawMasks(project: StudioProject, sourceTime: TimeInterval,
                          transform: ZoomTransform, imageRect: CGRect,
                          screen: CGImage?, in context: CGContext) {
        let live = project.masks.filter { $0.covers(sourceTime) }
        guard !live.isEmpty else { return }

        for mask in live {
            let rects = mask.rects.compactMap { box -> CGRect? in
                canvasRect(box.rect, project: project, transform: transform, imageRect: imageRect)
            }
            guard !rects.isEmpty else { continue }

            if mask.mode == .highlight {
                // The inverse: everything *outside* is dimmed. Drawn as one even-odd fill so the
                // regions punch through a single wash rather than each darkening the last.
                let path = CGMutablePath()
                path.addRect(imageRect)
                for rect in rects {
                    if mask.isEllipse { path.addEllipse(in: rect) } else { path.addRect(rect) }
                }
                context.saveGState()
                context.addPath(path)
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0,
                                             alpha: CGFloat(mask.dimming)))
                context.fillPath(using: .evenOdd)
                context.restoreGState()
                continue
            }

            for (index, rect) in rects.enumerated() {
                drawObscured(mask: mask, rect: rect,
                             sourceRect: mask.rects[index].rect, screen: screen, in: context)
            }
        }
    }

    private static func drawObscured(mask: StudioMask, rect: CGRect, sourceRect: CGRect,
                                     screen: CGImage?, in context: CGContext) {
        context.saveGState()
        let shape = CGMutablePath()
        if mask.isEllipse { shape.addEllipse(in: rect) } else { shape.addRect(rect) }
        context.addPath(shape)
        context.clip()

        switch mask.mode {
        case .secureBlur, .solid, .highlight:
            // `secureBlur`'s contract, kept: nothing survives but the region's mean colour, and the
            // texture over it comes from the seed rather than from the pixels. A blur that can be
            // inverted is not a redaction, and the README says so at length.
            let mean = averageColour(of: screen, in: sourceRect)
                ?? RGBAColour(r: 0.1, g: 0.1, b: 0.12)
            context.setFillColor(mean.cgColor)
            context.fill(rect)
            if mask.mode == .secureBlur {
                drawSeededTexture(seed: mask.seed, in: rect, context: context)
            }
        case .smoothBlur, .pixellate:
            let mean = averageColour(of: screen, in: sourceRect)
                ?? RGBAColour(r: 0.1, g: 0.1, b: 0.12)
            context.setFillColor(mean.cgColor)
            context.fill(rect)
        }
        context.restoreGState()
    }

    /// Grain from a seeded generator. Deterministic, so the same project exports identically twice,
    /// and carrying no information about what it covers.
    private static func drawSeededTexture(seed: UInt64, in rect: CGRect, context: CGContext) {
        var state = seed | 1
        func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1000) / 1000
        }
        let cell = max(6, min(rect.width, rect.height) / 8)
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1,
                                             alpha: CGFloat(next() * 0.06)))
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell
            }
            y += cell
        }
    }

    /// The mean of the region the mask actually covers.
    ///
    /// **The rect is in recording pixels, not canvas points.** Taking it from the whole image — as
    /// this did first — makes a small mask show the average of the entire screen, which is both
    /// wrong-looking and a quiet way for the redaction to stop matching its surroundings.
    static func averageColour(of image: CGImage?, in rect: CGRect) -> RGBAColour? {
        guard let image else { return nil }
        let region = rect.integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let cropped = region.isEmpty ? image : (image.cropping(to: region) ?? image)
        guard let grid = BackgroundCompositor.grid(from: cropped, side: 8) else { return nil }
        let mean = grid.cells.reduce(into: (0.0, 0.0, 0.0)) { sum, cell in
            sum.0 += cell.r; sum.1 += cell.g; sum.2 += cell.b
        }
        let count = Double(max(1, grid.cells.count))
        return RGBAColour(r: mean.0 / count, g: mean.1 / count, b: mean.2 / count)
    }

    /// The camera, in canvas space: it belongs to the finished video rather than to the recording,
    /// so a zoom must not move it.
    static func drawCamera(project: StudioProject, sourceTime: TimeInterval,
                           transform: ZoomTransform, canvas: CGSize,
                           camera: CGImage?, in context: CGContext,
                           clipSource: Range<TimeInterval>? = nil) {
        guard let camera,
              let state = CameraLayoutResolver.state(at: sourceTime,
                                                     segments: project.cameraSegments,
                                                     settings: project.camera,
                                                     canvas: canvas,
                                                     zoom: transform.scale,
                                                     clipSource: clipSource) else { return }

        let path = CGPath.rounded(state.rect, cornerRadius: state.cornerRadius)
        if let shadow = project.camera.shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -shadow.offsetY),
                              blur: shadow.radius,
                              color: CGColor(red: 0, green: 0, blue: 0,
                                             alpha: CGFloat(shadow.opacity)))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.setAlpha(CGFloat(state.opacity))
        context.addPath(path)
        context.clip()
        if project.camera.mirrored {
            // Front cameras look wrong un-mirrored — people expect the reflection they rehearsed in.
            context.translateBy(x: state.rect.midX * 2, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.drawFlipped(camera, in: BlurredBackdrop.fill(
            CGSize(width: camera.width, height: camera.height), into: state.rect.size)
            .offsetBy(dx: state.rect.minX, dy: state.rect.minY))
        context.restoreGState()
    }

    /// Recorded keys, as pills.
    static func drawKeystrokes(project: StudioProject, sourceTime: TimeInterval,
                               events: EventLog, canvas: CGSize, in context: CGContext) {
        guard project.keystrokes.isEnabled else { return }
        let pills = KeystrokeOverlay.pills(at: sourceTime, keys: events.keys,
                                           settings: project.keystrokes)
        guard !pills.isEmpty else { return }
        KeystrokeRenderer.draw(pills, settings: project.keystrokes, canvas: canvas, in: context)
    }

    /// Recording pixels to canvas points for a rectangle, through the crop and the zoom.
    private static func canvasRect(_ rect: CGRect, project: StudioProject,
                                   transform: ZoomTransform, imageRect: CGRect) -> CGRect? {
        let cropped = project.cropRect ?? CGRect(origin: .zero, size: project.canvasSize)
        let visible = ZoomResolver.sourceRect(for: transform, frameSize: cropped.size)
        guard visible.width > 0, visible.height > 0 else { return nil }
        let scaleX = imageRect.width / visible.width
        let scaleY = imageRect.height / visible.height
        return CGRect(x: imageRect.minX + (rect.minX - cropped.minX - visible.minX) * scaleX,
                      y: imageRect.minY + (rect.minY - cropped.minY - visible.minY) * scaleY,
                      width: rect.width * scaleX,
                      height: rect.height * scaleY)
    }
}
