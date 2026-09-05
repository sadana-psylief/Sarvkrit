// Composes the release-note images and the DMG background from the previews `make preview` writes.
//
//     make preview
//     swift scripts/make-release-art.swift build/preview docs/images
//
// Nothing here photographs anything. The snapshot suites already render every panel, the capture
// bar and the markup canvas to PNG at 2x — see Tests/SarvkritTests/PreviewDirectory.swift — so this
// only frames what they produced. That matters more than the saved effort: the pictures in the
// release notes are then the same views the tests assert on, and they cannot drift from the app
// without a test noticing first.
//
// Saffron lives in scripts/make-icon.swift and is repeated here rather than shared, for the same
// reason it is stated there: two standalone scripts with no build system between them.
import AppKit
import CoreGraphics
import Foundation

let previewDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/preview"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "docs/images"

let saffron = CGColor(srgbRed: 0.980, green: 0.694, blue: 0.216, alpha: 1)
let ember = CGColor(srgbRed: 0.851, green: 0.400, blue: 0.043, alpha: 1)
let paper = CGColor(srgbRed: 0.976, green: 0.969, blue: 0.957, alpha: 1)
let paperEdge = CGColor(srgbRed: 0.937, green: 0.925, blue: 0.906, alpha: 1)
let ink = NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1)
let inkSoft = NSColor(srgbRed: 0.42, green: 0.40, blue: 0.38, alpha: 1)

func load(_ name: String) -> CGImage? {
    let path = "\(previewDir)/\(name).png"
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("missing preview: \(path)\n".data(using: .utf8)!)
        return nil
    }
    return cg
}

func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ ctx: CGContext, to name: String) {
    guard let image = ctx.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write("failed to encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = "\(outDir)/\(name)"
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(ctx.width)x\(ctx.height))")
}

/// The warm ground every piece of this art shares, plus a saffron bloom in one corner so the set
/// reads as one family rather than three screenshots that happen to be the same width.
func paint(ground ctx: CGContext, _ rect: CGRect, bloomAt corner: CGPoint) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [paper, paperEdge] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.minX, y: rect.minY),
        options: [])
    ctx.saveGState()
    ctx.drawRadialGradient(
        CGGradient(colorsSpace: space,
                   colors: [saffron.copy(alpha: 0.30)!, saffron.copy(alpha: 0)!] as CFArray,
                   locations: [0, 1])!,
        startCenter: corner, startRadius: 0,
        endCenter: corner, endRadius: rect.width * 0.62, options: [])
    ctx.restoreGState()
}

/// Draws `image` with a rounded clip and a soft drop shadow, the way the app's own panels sit on
/// the desktop. Without the shadow a light panel on a light ground has no edge at all.
func place(_ image: CGImage, in ctx: CGContext, at frame: CGRect, radius: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 34,
                  color: CGColor(srgbRed: 0.20, green: 0.14, blue: 0.06, alpha: 0.22))
    ctx.beginPath()
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
    ctx.clip()
    ctx.draw(image, in: frame)
    ctx.restoreGState()
}

func text(_ string: String, _ font: NSFont, _ colour: NSColor, in ctx: CGContext,
          at point: CGPoint, centredOn width: CGFloat? = nil) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
    let size = (string as NSString).size(withAttributes: attributes)
    let x = width.map { point.x + ($0 - size.width) / 2 } ?? point.x
    (string as NSString).draw(at: CGPoint(x: x, y: point.y), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Release-note cards

/// One fixed width for all three, because GitHub scales every image in a release body to the same
/// column: cards of different widths would render the app at three different sizes on the page.
let cardWidth: CGFloat = 1800
let cardPad: CGFloat = 96

/// - Parameter maxScale: sources are already 2x renders, so anything above a little enlargement
///   would be visibly soft. Capped rather than stretched to fill.
func card(_ image: CGImage, named name: String, maxScale: CGFloat = 1.6) {
    let available = cardWidth - cardPad * 2
    let scale = min(maxScale, available / CGFloat(image.width))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    let height = size.height + cardPad * 2
    let ctx = context(Int(cardWidth), Int(height.rounded()))
    let bounds = CGRect(x: 0, y: 0, width: cardWidth, height: height)
    paint(ground: ctx, bounds, bloomAt: CGPoint(x: cardWidth * 0.14, y: height))
    place(image, in: ctx,
          at: CGRect(x: (cardWidth - size.width) / 2, y: cardPad,
                     width: size.width, height: size.height),
          radius: 24 * scale)
    write(ctx, to: name)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// Two images in one card: the tools, then what they produce.
///
/// Neither half works alone. `editor-*` is the real editor chrome with every tool named, but the
/// suite renders it over an empty placeholder canvas, so on its own it is mostly flat grey.
/// `markup-composite` is a finished shot — mesh background, bowed arrow, counter, drop shadow —
/// but out of context it reads as abstract shapes rather than as something the app made. Together
/// they say "these are the tools; this is the result".
func stackedCard(_ top: CGImage, _ bottom: CGImage, named name: String,
                 topCrop: CGFloat, bottomWidth: CGFloat) {
    let available = cardWidth - cardPad * 2
    let gap: CGFloat = 56

    let cropped = top.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(top.width), height: topCrop))!
    let topScale = available / CGFloat(cropped.width)
    let topSize = CGSize(width: available, height: CGFloat(cropped.height) * topScale)

    let bottomScale = bottomWidth / CGFloat(bottom.width)
    let bottomSize = CGSize(width: bottomWidth, height: CGFloat(bottom.height) * bottomScale)

    let height = cardPad * 2 + topSize.height + gap + bottomSize.height
    let ctx = context(Int(cardWidth), Int(height.rounded()))
    paint(ground: ctx, CGRect(x: 0, y: 0, width: cardWidth, height: height),
          bloomAt: CGPoint(x: cardWidth * 0.14, y: height))
    place(cropped, in: ctx,
          at: CGRect(x: cardPad, y: height - cardPad - topSize.height,
                     width: topSize.width, height: topSize.height),
          radius: 24 * topScale)
    place(bottom, in: ctx,
          at: CGRect(x: (cardWidth - bottomSize.width) / 2, y: cardPad,
                     width: bottomSize.width, height: bottomSize.height),
          radius: 20)
    write(ctx, to: name)
}

// The capture bar is the one thing every screenshot starts with, so it leads.
if let bar = load("confirm-bar-area") { card(bar, named: "capture.png") }
// `cropping` measures from the top of the CGImage, which is where the two toolbar rows end at
// 202px; the rest of that render is the placeholder canvas and the zoom bar under it.
if let chrome = load("editor-text-NSAppearanceNameAqua"), let markup = load("markup-composite") {
    stackedCard(chrome, markup, named: "editor.png", topCrop: 202, bottomWidth: 1200)
}
// The whole dropdown, not just a panel: header, strip, live readings and the menu rows under it.
if let panel = load("menu-system-light") { card(panel, named: "dashboard.png", maxScale: 1.35) }

// MARK: - DMG background
//
// Sized to `--window-size` in scripts/build-dmg.sh, which the two icon positions there also follow.
// Everything is kept out of the horizontal band the icons occupy: art behind a 128pt icon reads as
// noise, not as design.

let dmgSize = CGSize(width: 700, height: 460)
/// Where build-dmg.sh puts the two icons, measured from the *top* — Finder's icon view origin —
/// and converted here, because CoreGraphics measures from the bottom.
let iconCentreFromTop: CGFloat = 250
let appIconX: CGFloat = 200
let dropIconX: CGFloat = 500

func dmgBackground(scale: CGFloat) -> CGContext {
    let w = dmgSize.width * scale, h = dmgSize.height * scale
    let ctx = context(Int(w), Int(h))
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    paint(ground: ctx, bounds, bloomAt: CGPoint(x: w * 0.08, y: h * 1.02))

    // A second bloom on the far side, so the arrow between the icons crosses a warm field rather
    // than fading into a flat corner.
    ctx.drawRadialGradient(
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                   colors: [ember.copy(alpha: 0.12)!, ember.copy(alpha: 0)!] as CFArray,
                   locations: [0, 1])!,
        startCenter: CGPoint(x: w * 0.98, y: 0), startRadius: 0,
        endCenter: CGPoint(x: w * 0.98, y: 0), endRadius: w * 0.5, options: [])

    text("Sarvkrit", .systemFont(ofSize: 34 * scale, weight: .semibold), ink, in: ctx,
         at: CGPoint(x: 0, y: h - 74 * scale), centredOn: w)
    text("The things macOS does differently than you’d expect. Fixed.",
         .systemFont(ofSize: 14 * scale, weight: .regular), inkSoft, in: ctx,
         at: CGPoint(x: 0, y: h - 100 * scale), centredOn: w)

    // The arrow, in the gap between the two icons and nowhere near either.
    let y = (h - iconCentreFromTop * scale)
    let from = (appIconX + 84) * scale, to = (dropIconX - 84) * scale
    ctx.setStrokeColor(ember.copy(alpha: 0.55)!)
    ctx.setLineWidth(3 * scale)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [10 * scale, 9 * scale])
    ctx.move(to: CGPoint(x: from, y: y))
    ctx.addLine(to: CGPoint(x: to - 12 * scale, y: y))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setFillColor(ember.copy(alpha: 0.75)!)
    ctx.move(to: CGPoint(x: to + 4 * scale, y: y))
    ctx.addLine(to: CGPoint(x: to - 16 * scale, y: y + 10 * scale))
    ctx.addLine(to: CGPoint(x: to - 16 * scale, y: y - 10 * scale))
    ctx.closePath()
    ctx.fillPath()

    text("Drag Sarvkrit into Applications",
         .systemFont(ofSize: 13 * scale, weight: .medium), inkSoft, in: ctx,
         at: CGPoint(x: 0, y: 54 * scale), centredOn: w)
    text("Nineteen features. Nothing runs unless you switch it on.",
         .systemFont(ofSize: 11 * scale, weight: .regular),
         inkSoft.withAlphaComponent(0.8), in: ctx,
         at: CGPoint(x: 0, y: 32 * scale), centredOn: w)
    return ctx
}

write(dmgBackground(scale: 1), to: "dmg-background.png")
write(dmgBackground(scale: 2), to: "dmg-background@2x.png")
