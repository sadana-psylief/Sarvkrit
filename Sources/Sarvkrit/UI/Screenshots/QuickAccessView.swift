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
    /// Flicking the thumbnail off the side of the screen. Separate from `onClose` because it is
    /// the same "put it away" but reached without aiming at a 16pt button.
    var onSwipeAway: (() -> Void)?
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

            // **Inside the stack and *under* the controls, never as a trailing `.overlay`.**
            // As an overlay this sat on top of everything, and `DragSourceView.mouseDown`
            // swallows the event without forwarding it — so every button here, Discard
            // included, was unclickable, and the overlay could not be put away at all.
            // Below the hover layer, a drag anywhere that is not a button still starts one.
            CaptureDragSource(url: fileURL, preview: image, onSwipeAway: onSwipeAway)

            if isHovering { hoverLayer }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .contextMenu { contextMenu }
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
            // Not hit-testable: it covers the drag source underneath, and a dimming wash that
            // swallowed drags would trade one dead gesture for another.
            Color.black.opacity(0.35).allowsHitTesting(false)

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

    /// The right-click menu, which the reference has and we did not.
    ///
    /// Worth having beyond parity: it is reachable without hovering the exact pixel a small
    /// round button occupies, so it is the way out when the buttons are missed.
    @ViewBuilder private var contextMenu: some View {
        if let onAnnotate { Button("Open Annotation Tool…", action: onAnnotate) }
        if let onPin { Button("Pin to the Screen", action: onPin) }
        Divider()
        Button("Copy", action: onCopy)
        Button("Save", action: onSave)
        Button("Show in Finder", action: onReveal)
        Divider()
        Button("Close", action: onClose)
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
