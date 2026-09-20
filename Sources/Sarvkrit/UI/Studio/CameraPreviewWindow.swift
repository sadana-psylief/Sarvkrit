import AVFoundation
import AppKit
import SwiftUI

/// The camera, on screen, while a recording is running.
///
/// **This is the thing that was missing.** The camera could be switched on and recorded, and the
/// editor could composite it afterwards, but during the take there was nothing to see — so the
/// only sign the camera was on at all was the green light in the menu bar, and "I cannot see my
/// webcam circle while recording" is exactly what that looks like from the outside.
///
/// **It shows the recorder's own session rather than opening a second one.** Two `AVCaptureSession`s
/// on one camera is how the pre-record bar's preview and the recorder ended up fighting over the
/// device; an `AVCaptureVideoPreviewLayer` is a view of a session, not another claim on the camera.
///
/// Registered with `CaptureOverlayGuard`, because ⌃⇧⎋ is documented as always clearing the screen.
@MainActor
final class CameraPreviewWindowController {
    static let shared = CameraPreviewWindowController()

    private var panel: FloatingPanel?

    var isShowing: Bool { panel != nil }

    /// The side of the circle, in points. Large enough to see yourself in, small enough to leave
    /// the screen you are demonstrating alone.
    private static let side: CGFloat = 168
    private static let margin: CGFloat = 24

    func show(_ layer: AVCaptureVideoPreviewLayer, settings: CameraSettings = CameraSettings()) {
        dismiss()

        let side = Self.side
        // Exactly the picture, nothing around it. It carried a white outline and a caption strip
        // before, and against a busy screen the pair read as a box drawn over the work rather than
        // as a camera. What the caption said now lives in the right-click menu.
        let size = NSSize(width: side, height: side)
        guard let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame else { return }

        // `unitPoint` runs 0…1 leading-to-trailing and top-to-bottom; AppKit's origin is at the
        // bottom, so the vertical fraction is measured down from the top edge.
        let point = settings.corner.unitPoint
        let freeX = max(0, visible.width - size.width - Self.margin * 2)
        let freeY = max(0, visible.height - size.height - Self.margin * 2)
        let origin = CGPoint(
            x: visible.minX + Self.margin + freeX * point.x,
            y: visible.maxY - Self.margin - size.height - freeY * point.y)

        // **Not key, and never activating.** Taking focus mid-recording would steal it from the
        // app being demonstrated, which is the one thing a recording overlay must not do.
        let panel = FloatingPanel(
            contentRect: NSRect(origin: origin, size: size),
            style: .init(level: .modalPanel, acceptsKey: false, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: false))
        panel.contentView = NSHostingView(rootView: CameraPreviewWindowView(
            layer: layer, settings: settings, side: side,
            onHide: { [weak self] in self?.dismiss() }))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CameraPreviewWindowView: View {
    let layer: AVCaptureVideoPreviewLayer
    let settings: CameraSettings
    let side: CGFloat
    let onHide: () -> Void

    var body: some View {
        CameraPreviewLayerView(layer: layer, mirrored: settings.mirrored)
            .frame(width: side, height: side)
            .clipShape(shape)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .help("This preview is not part of the recording. Right-click to hide it.")
            .contextMenu {
                // **Where the caption went.** The point still has to be reachable — "why is there a
                // hole where the camera was" is a confusing few minutes otherwise — but it does not
                // have to sit on screen through the whole take.
                Text("This preview is not in the recording")
                Divider()
                Button("Hide Preview", action: onHide)
            }
    }

    /// One shape for all three settings: a circle is a rounded rectangle whose radius is half its
    /// side, and a rectangle one whose radius is zero.
    private var shape: RoundedRectangle {
        let radius: CGFloat
        switch settings.shape {
        case .circle: radius = side / 2
        case .squircle: radius = side * CGFloat(settings.cornerRadiusFraction)
        case .rectangle: radius = 0
        }
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Hosts the capture preview layer. The layer belongs to the recorder's session; this only draws it.
private struct CameraPreviewLayerView: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    let mirrored: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        layer.videoGravity = .resizeAspectFill
        // Front cameras look wrong un-mirrored — you reach left and the reflection reaches right.
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        layer.frame = nsView.bounds
    }
}
