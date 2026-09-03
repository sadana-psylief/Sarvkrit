import AppKit
import SwiftUI

/// A screenshot floating above everything else.
struct PinnedShotView: View {
    let image: NSImage
    @Binding var opacity: Double
    @Binding var isLocked: Bool
    let onClose: () -> Void
    let onCopy: () -> Void
    let onResize: (CGSize) -> Void

    @State private var isHovering = false

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
            chip(isLocked ? "lock.fill" : "lock.open", "Lock Mode") { isLocked.toggle() }
            Slider(value: Binding(
                get: { opacity },
                set: { opacity = PinnedShotGeometry.clampedOpacity($0) }),
                   in: PinnedShotGeometry.minimumOpacity...1)
                .frame(width: 64)
                .help("Opacity")
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
    private var resizeGrip: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .frame(width: 18, height: 18)
                .position(x: proxy.size.width - 9, y: proxy.size.height - 9)
                .gesture(DragGesture()
                    .onChanged { value in
                        guard !isLocked else { return }
                        onResize(CGSize(width: value.translation.width,
                                        height: -value.translation.height))
                    })
        }
    }
}
