import AppKit
import SwiftUI

/// The thumbnail that appears after a capture.
struct QuickAccessView: View {
    let image: NSImage
    let fileURL: URL
    let dimensions: String
    /// Nil hides the button — how a not-yet-built half of the feature is absent rather than a
    /// control that does nothing.
    var onAnnotate: (() -> Void)?
    var onPin: (() -> Void)?
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 130)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                    // The whole thumbnail is the drag handle, which is what people reach for.
                    .overlay(CaptureDragSource(url: fileURL, preview: image))

                if isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .clickableCursor()
                    .help("Discard this capture")
                }
            }

            HStack(spacing: Theme.Space.sm) {
                Text(dimensions)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                action("doc.on.doc", "Copy", onCopy)
                if let onAnnotate { action("pencil.tip.crop.circle", "Annotate", onAnnotate) }
                if let onPin { action("pin", "Pin to screen", onPin) }
                action("folder", "Show in Finder", onReveal)
            }
            .padding(.horizontal, 2)
        }
        .padding(Theme.Space.sm)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
            .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .onHover { hovering in
            isHovering = hovering
            onHoverChange(hovering)
        }
    }

    private func action(_ symbol: String, _ label: String,
                        _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help(label)
        .accessibilityLabel(label)
    }
}
