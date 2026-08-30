// Renders Sarvkrit's app icon into the asset catalog.
// Saffron at full strength lives here and nowhere else: the app UI uses Color.accentColor.
import AppKit
import CoreGraphics
import Foundation

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/Sarvkrit/Resources/Assets.xcassets/AppIcon.appiconset"

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS app icons carry their own shape and sit inset inside the canvas.
    let inset = s * 0.0977
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(srgbRed: 0.980, green: 0.694, blue: 0.216, alpha: 1),
            CGColor(srgbRed: 0.851, green: 0.400, blue: 0.043, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    ctx.restoreGState()

    // A hairline of white along the top edge, the way system icons catch light.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // The ⌘ mark, drawn from the system symbol so it matches the menu bar glyph.
    let glyphSize = rect.width * 0.52
    let config = NSImage.SymbolConfiguration(pointSize: glyphSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "command", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let drawn = NSImage(size: NSSize(width: s, height: s))
        drawn.lockFocus()
        if let gctx = NSGraphicsContext.current {
            gctx.cgContext.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            let sz = symbol.size
            let origin = NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2)
            symbol.draw(
                in: NSRect(origin: origin, size: sz),
                from: .zero, operation: .sourceOver, fraction: 1
            )
        }
        drawn.unlockFocus()

        if let tiff = drawn.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let cgGlyph = rep.cgImage {
            // Tint the (black) symbol white by clipping to it and filling.
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: s, height: s), mask: cgGlyph)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            ctx.restoreGState()
        }
    }

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for size in sizes {
    guard let data = renderIcon(size: size) else {
        FileHandle.standardError.write("failed to render \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    let path = "\(outDir)/icon_\(size).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
