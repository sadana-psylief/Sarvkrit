import AppKit
import SwiftUI

/// A screenshot floating above everything else.
struct PinnedShotView: View {
    /// Observed, so changing opacity or the lock actually redraws. Read through plain bindings it
    /// did not — see `PinnedShotController.Pin`.
    @ObservedObject var pin: PinnedShotController.Pin
    let image: NSImage
    let onOpacityChange: (Double) -> Void
    let onLockChange: (Bool) -> Void
    let onClose: () -> Void
    let onCopy: () -> Void
    let onResize: (CGSize) -> Void

    @State private var isHovering = false
    /// The last cumulative translation seen from the resize drag.
    ///
    /// `DragGesture` reports translation from the *start* of the gesture, and the handler applies
    /// what it is given to the window's *current* frame — so passing the total each time made the
    /// deltas compound. A hundred-point drag over twenty events grew the window by about a
    /// thousand, until its close button was off the screen.
    @State private var lastTranslation: CGSize = .zero

    private var opacity: Double { pin.opacity }
    private var isLocked: Bool { pin.isLocked }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .opacity(opacity)
                // The image is the drag handle, the way a title bar would be if there were one.
                .background(WindowDragHandle())

            if isHovering && !isLocked {
                controls
                    .padding(6)
                    .transition(.opacity)
            }

            resizeGrip
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(isLocked
                          ? Color.accentColor.opacity(0.8)
                          : Color(nsColor: .separatorColor).opacity(0.6),
                          lineWidth: isLocked ? 2 : 0.5))
        .onHover { isHovering = $0 }
        .standardMotion(value: isHovering)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            chip("xmark", "Close", onClose)
            chip("doc.on.doc", "Copy", onCopy)
            chip(isLocked ? "lock.fill" : "lock.open",
                 isLocked ? "Locked — clicks pass through" : "Lock Mode") {
                onLockChange(!isLocked)
            }
            // The slider had no icon and no label, so a bare 64pt track in a capsule was left to
            // explain itself. The symbol is what says "this is how see-through it is".
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { opacity }, set: onOpacityChange),
                   in: PinnedShotGeometry.minimumOpacity...1)
                .frame(width: 64)
                .help("Opacity")
                .accessibilityLabel("Opacity")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func chip(_ symbol: String, _ label: String,
                      _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help(label)
        .accessibilityLabel(label)
    }

    /// Bottom-right corner drag. A borderless panel has no resize edge of its own.
    ///
    /// Visible, where it used to be `Color.clear`: an invisible target sitting exactly where
    /// someone aiming to drag the pin by its corner will land is a target they hit by accident and
    /// cannot find on purpose.
    private var resizeGrip: some View {
        GeometryReader { proxy in
            ResizeCorner()
                .fill(Color.white.opacity(isHovering && !isLocked ? 0.55 : 0))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle().inset(by: -4))
                .position(x: proxy.size.width - 9, y: proxy.size.height - 9)
                .clickableCursor()
                .help("Drag to resize")
                .gesture(DragGesture()
                    .onChanged { value in
                        guard !isLocked else { return }
                        // The increment since the last event, not the total since the start.
                        let delta = CGSize(
                            width: value.translation.width - lastTranslation.width,
                            height: -(value.translation.height - lastTranslation.height))
                        lastTranslation = value.translation
                        onResize(delta)
                    }
                    .onEnded { _ in lastTranslation = .zero })
        }
    }
}

/// Three diagonal strokes, the way macOS marks a resizable corner.
private struct ResizeCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for inset in stride(from: 0.0, to: 1.0, by: 0.34) {
            let offset = rect.width * inset
            path.move(to: CGPoint(x: rect.maxX - offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - offset))
        }
        return path.strokedPath(.init(lineWidth: 1.5, lineCap: .round))
    }
}
