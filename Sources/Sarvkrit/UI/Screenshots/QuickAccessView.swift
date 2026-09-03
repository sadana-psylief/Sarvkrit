import AppKit
import SwiftUI

/// The thumbnail that appears after a capture.
///
/// **At rest it is only the picture.** Every control is revealed on hover. The point of this
/// overlay is that the capture is already done and already draggable — a row of buttons sitting
/// permanently under it turns a glanceable result into a small form, and it was the first thing
/// that made the old version feel unfinished.
struct QuickAccessView: View {
    let image: NSImage
    let fileURL: URL
    let dimensions: String
    /// Nil hides the control. That is how a half of the feature that doesn't exist yet is absent
    /// rather than present and inert.
    var onAnnotate: (() -> Void)?
    var onPin: (() -> Void)?
    let onCopy: () -> Void
    let onSave: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void
    let onHoverChange: (Bool) -> Void

    @State private var isHovering = false
    @State private var hasAppeared = false

    private var width: CGFloat { CaptureChrome.Metrics.thumbnailWidth }
    /// The frame follows the capture's shape rather than forcing a box, so a tall screenshot isn't
    /// letterboxed into a landscape card. Clamped, or a very tall capture makes a tower.
    private var height: CGFloat {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1.6
        return min(max(width / max(aspect, 0.4), 90), width * 1.15)
    }

    private var radius: CGFloat { CaptureChrome.Metrics.thumbnailRadius }

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()

            if isHovering { hoverLayer }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        // The whole thumbnail is the drag handle, which is what people reach for.
        .overlay(CaptureDragSource(url: fileURL, preview: image))
        .scaleEffect(hasAppeared ? 1 : 0.92)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { hasAppeared = true }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            onHoverChange(hovering)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture, \(dimensions)")
    }

    private var hoverLayer: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    pill("Copy", action: onCopy)
                    pill("Save", action: onSave)
                }
                Text(dimensions)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            VStack {
                HStack {
                    corner("xmark", "Discard", onClose)
                    Spacer()
                    if let onPin { corner("pin", "Pin to screen", onPin) }
                }
                Spacer()
                HStack {
                    if let onAnnotate {
                        corner("pencil.tip", "Annotate", onAnnotate)
                    }
                    Spacer()
                    corner("folder", "Show in Finder", onReveal)
                }
            }
            .padding(10)
        }
        .transition(.opacity)
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.9))
                .frame(width: 62, height: 28)
                .background(Color.white.opacity(0.85), in: Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }

    private func corner(_ symbol: String, _ label: String,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.85), in: Circle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help(label)
        .accessibilityLabel(label)
    }
}
