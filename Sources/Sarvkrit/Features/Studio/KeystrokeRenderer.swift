import AppKit
import CoreGraphics
import Foundation

/// Drawing the keystroke pills.
enum KeystrokeRenderer {

    static func draw(_ pills: [KeystrokeOverlay.Pill], settings: KeystrokeSettings,
                     canvas: CGSize, in context: CGContext) {
        let size = CGFloat(settings.sizeFraction) * canvas.height
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let padding = size * 0.5
        let gap = size * 0.32
        let margin = canvas.height * 0.05

        // Measured first, then placed as a block, so the row grows away from its corner rather
        // than sliding along the edge as keys are added.
        let drawn = pills.map { pill -> (text: NSAttributedString, width: CGFloat, alpha: Double) in
            let label = pill.repeatCount > 1 ? "\(pill.label) ×\(pill.repeatCount)" : pill.label
            let text = NSAttributedString(
                string: label,
                attributes: [.font: font, .foregroundColor: NSColor.white])
            return (text, text.size().width + padding * 2, pill.opacity)
        }
        let totalWidth = drawn.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, pills.count - 1))
        let height = size + padding

        let unit = settings.corner.unitPoint
        let free = CGSize(width: max(0, canvas.width - totalWidth - margin * 2),
                          height: max(0, canvas.height - height - margin * 2))
        var x = margin + free.width * unit.x
        let y = margin + free.height * unit.y

        for pill in drawn {
            let rect = CGRect(x: x, y: y, width: pill.width, height: height)
            context.saveGState()
            context.setAlpha(CGFloat(pill.alpha))
            context.addPath(CGPath.rounded(rect, cornerRadius: height * 0.28))
            context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0.86))
            context.fillPath()

            // Core Text draws bottom-up; the surrounding context is top-left, so the label is
            // flipped back for its own draw and no further.
            context.translateBy(x: 0, y: rect.midY * 2)
            context.scaleBy(x: 1, y: -1)
            pill.text.draw(at: CGPoint(x: rect.minX + padding,
                                       y: rect.midY - pill.text.size().height / 2))
            context.restoreGState()
            x += pill.width + gap
        }
    }
}
