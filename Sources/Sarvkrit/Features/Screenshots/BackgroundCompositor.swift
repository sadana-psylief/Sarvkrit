import CoreGraphics
import Foundation

/// Drawing a screenshot onto a background.
///
/// Layout is `BackgroundLayout`'s job and is pure; this is the drawing half. The order matters
/// and is stated once here: **fill → shadow → clip → image.** The shadow is drawn as a
/// rounded-rect fill *underneath* the image rather than as a shadow on the image itself, so it
/// follows the corner radius instead of tracing the bitmap's square edges.
enum BackgroundCompositor {

    /// What a fill needs from outside itself.
    ///
    /// Two of the fills cannot be painted from their own stored value: a blurred backdrop is
    /// derived from the capture, and a wallpaper is a filename that somebody has to turn into
    /// pixels. **Resolved by the caller and handed in**, rather than reaching into a store from
    /// here — `WallpaperStore` is main-actor and the export path is not, and a compositor that
    /// touches the filesystem is a compositor that cannot be tested with a bitmap.
    struct Sources {
        /// The capture itself, for `.blurred`.
        var base: CGImage?
        /// The already-loaded wallpaper, for `.image`. Nil means the file has gone.
        var wallpaper: CGImage?

        init(base: CGImage? = nil, wallpaper: CGImage? = nil) {
            self.base = base
            self.wallpaper = wallpaper
        }
    }

    /// Everything behind and around the screenshot: the fill, and the shadow that sits under it.
    ///
    /// Split out of `render` so the live canvas can draw the same surround without flattening the
    /// image first — which is what makes the background visible while you are choosing it, rather
    /// than only once you save.
    static func drawSurround(style: CaptureBackground,
                             canvas: CGRect,
                             imageRect: CGRect,
                             in context: CGContext,
                             sources: Sources = Sources()) {
        drawFill(style.fill, in: canvas, context: context, sources: sources)

        guard let shadow = style.shadow else { return }
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -shadow.offsetY),
                          blur: shadow.radius,
                          color: CGColor(red: shadow.colour.r, green: shadow.colour.g,
                                         blue: shadow.colour.b, alpha: shadow.opacity))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: imageRect,
                               cornerWidth: style.cornerRadius,
                               cornerHeight: style.cornerRadius, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// The rounded-corner clip the screenshot is drawn through.
    static func clipPath(imageRect: CGRect, style: CaptureBackground) -> CGPath {
        CGPath(roundedRect: imageRect, cornerWidth: style.cornerRadius,
               cornerHeight: style.cornerRadius, transform: nil)
    }

    static func render(_ image: CGImage, style: CaptureBackground,
                       sources: Sources = Sources()) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let (canvas, imageRect) = BackgroundLayout.compute(imageSize: imageSize, style: style)
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }

        guard let context = CGContext(
            data: nil, width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Work in document space: top-left origin, so `imageRect` means what it says.
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)

        // The blurred fill derives its backdrop from the capture, so if the caller did not name
        // one, the capture being composited is the obvious answer.
        var sources = sources
        if sources.base == nil { sources.base = image }
        drawSurround(style: style, canvas: CGRect(origin: .zero, size: canvas),
                     imageRect: imageRect, in: context, sources: sources)
        let clip = clipPath(imageRect: imageRect, style: style)

        context.saveGState()
        context.addPath(clip)
        context.clip()
        // Same flip as the annotation renderer: this context was turned top-left above, so the
        // screenshot has to be drawn flipped or it composites upside down inside its own frame.
        context.drawFlipped(image, in: imageRect)
        context.restoreGState()

        return context.makeImage()
    }

    static func drawFill(_ fill: CaptureBackground.Fill, in rect: CGRect,
                         context: CGContext, sources: Sources = Sources()) {
        switch fill {
        case .none:
            break
        case .solid(let colour):
            context.setFillColor(colour.cgColor)
            context.fill(rect)
        case .gradient(let spec):
            draw(spec, in: rect, context: context)
        case .mesh(let spec):
            draw(spec, in: rect, context: context)
        case .builtIn(let id):
            draw(BackgroundCatalogue.mesh(for: id), in: rect, context: context)
        case .unknown:
            // Written by a newer build and kept verbatim, but we cannot paint what we cannot read.
            // Something neutral beats a transparent hole the user cannot see or explain.
            draw(BackgroundCatalogue.mesh(for: "slate"), in: rect, context: context)
        case .image:
            // A wallpaper the caller has already loaded. A missing file falls back to a mesh
            // rather than a transparent hole: the document still points at a wallpaper, so the
            // user can put the file back, but they must be able to *see* the composite meanwhile.
            guard let wallpaper = sources.wallpaper else {
                draw(BackgroundCatalogue.mesh(for: "slate"), in: rect, context: context)
                return
            }
            context.saveGState()
            context.clip(to: rect)
            context.interpolationQuality = .high
            context.drawFlipped(wallpaper,
                                in: BlurredBackdrop.fill(
                                    CGSize(width: wallpaper.width, height: wallpaper.height),
                                    into: rect.size))
            context.restoreGState()
        case .blurred(let blur):
            guard let base = sources.base,
                  let backdrop = BlurredBackdrop.render(base, size: rect.size, blur: blur) else {
                draw(BackgroundCatalogue.mesh(for: "slate"), in: rect, context: context)
                return
            }
            context.drawFlipped(backdrop, in: rect)
        }
    }

    /// Paints a mesh gradient.
    ///
    /// Rendered at the size it will occupy — see `MeshRenderer` for why the dither cannot be
    /// applied to a small buffer and stretched — then blitted. `interpolationQuality` is `.none`
    /// because the bitmap is already the right size; anything else would resample the dither and
    /// undo it.
    static func draw(_ spec: MeshSpec, in rect: CGRect, context: CGContext) {
        guard let image = MeshRenderer.image(spec,
                                             width: Int(rect.width.rounded()),
                                             height: Int(rect.height.rounded()))
        else { return }
        context.saveGState()
        context.interpolationQuality = image.width == Int(rect.width.rounded()) ? .none : .high
        context.drawFlipped(image, in: rect)
        context.restoreGState()
    }

    static func draw(_ spec: GradientSpec, in rect: CGRect, context: CGContext) {
        let colours = spec.stops.map { $0.colour.cgColor } as CFArray
        let locations = spec.stops.map { CGFloat($0.location) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colours, locations: locations) else { return }

        switch spec.kind {
        case .linear:
            let radians = spec.angle * .pi / 180
            let dx = cos(radians) * rect.width / 2
            let dy = sin(radians) * rect.height / 2
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX - dx, y: rect.midY - dy),
                end: CGPoint(x: rect.midX + dx, y: rect.midY + dy),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                endCenter: CGPoint(x: rect.midX, y: rect.midY),
                endRadius: max(rect.width, rect.height) / 2,
                options: [.drawsAfterEndLocation])
        }
    }

    /// Builds the downsampled grid Auto Balance works from.
    static func grid(from image: CGImage, side: Int = 32) -> AutoBalance.Grid? {
        let width = max(1, side), height = max(1, side)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let cells = (0..<(width * height)).map { index -> (r: Double, g: Double, b: Double) in
            let offset = index * 4
            return (Double(buffer[offset]) / 255,
                    Double(buffer[offset + 1]) / 255,
                    Double(buffer[offset + 2]) / 255)
        }
        return AutoBalance.Grid(width: width, height: height, cells: cells)
    }

    /// A whole Auto Balance pass.
    static func autoBalanced(_ image: CGImage, base: CaptureBackground = CaptureBackground())
        -> CaptureBackground {
        var style = base
        style.isAutoBalanced = true
        guard let grid = grid(from: image) else { return style }

        let bounds = AutoBalance.contentBounds(grid)
        style.padding = AutoBalance.padding(
            contentBounds: bounds,
            imageSize: CGSize(width: image.width, height: image.height))

        if let entry = AutoBalance.suggestedBackground(
            dominantHue: AutoBalance.dominantHue(grid),
            imageLuma: AutoBalance.meanLuma(grid)) {
            style.fill = .builtIn(id: entry.id)
        }
        return style
    }
}

/// Laying several captures out as one image.
enum ImageCombiner {

    /// The combined result becomes the base bitmap of a brand-new document, so the Background
    /// tool, every annotation tool, OCR and the file format all apply to it with no special
    /// casing at all.
    static func render(_ images: [CGImage],
                       mode: CombineLayout.Mode,
                       spacing: CGFloat,
                       normalize: CombineLayout.Normalize,
                       backgroundColour: RGBAColour? = nil) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let sizes = images.map { CGSize(width: $0.width, height: $0.height) }
        let (canvas, frames) = CombineLayout.compute(sizes: sizes, mode: mode,
                                                     spacing: spacing, normalize: normalize)
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }

        guard let context = CGContext(
            data: nil, width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        if let backgroundColour {
            context.setFillColor(backgroundColour.cgColor)
            context.fill(CGRect(origin: .zero, size: canvas))
        }

        // The layout is top-left; CGContext is bottom-left.
        for (image, frame) in zip(images, frames) {
            context.draw(image, in: CGRect(x: frame.minX,
                                           y: canvas.height - frame.maxY,
                                           width: frame.width, height: frame.height))
        }
        return context.makeImage()
    }
}
