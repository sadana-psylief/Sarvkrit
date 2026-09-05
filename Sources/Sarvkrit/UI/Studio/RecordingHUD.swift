import AppKit
import SwiftUI

/// The small panel that floats while a recording is running.
///
/// Modelled on `ScrollCaptureSession`'s HUD, and like it, **registered with
/// `CaptureOverlayGuard`** — ⌃⇧⎋ is documented as always clearing the screen, and this feature
/// must not be the exception that makes that promise false.
@MainActor
final class RecordingHUDController {
    static let shared = RecordingHUDController()

    private var panel: FloatingPanel?
    private var timer: Timer?
    private let model = RecordingHUDModel()

    var isShowing: Bool { panel != nil }

    var onStop: (() -> Void)?
    var onPauseResume: (() -> Void)?
    var onDiscard: (() -> Void)?

    func show(elapsed: @escaping () -> TimeInterval, dropped: @escaping () -> Int) {
        dismiss()
        model.elapsed = 0
        model.dropped = 0

        let size = NSSize(width: 300, height: 56)
        let frame = ScreenPlacement.screenUnderPointer()?.visibleFrame ?? .zero
        let panel = FloatingPanel(
            contentRect: NSRect(x: frame.midX - size.width / 2,
                                y: frame.minY + 40,
                                width: size.width, height: size.height),
            style: .init(level: .modalPanel, acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true))
        panel.contentView = NSHostingView(rootView: RecordingHUDView(
            model: model,
            onStop: { [weak self] in self?.onStop?() },
            onPauseResume: { [weak self] in
                self?.model.isPaused.toggle()
                self?.onPauseResume?()
            },
            onDiscard: { [weak self] in self?.onDiscard?() }))
        panel.orderFrontRegardless()
        self.panel = panel

        // Built once and updated through the model, not rebuilt per tick: rebuilding the hosting
        // view every second destroys any mouse-down in progress on its own buttons.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.model.elapsed = elapsed()
                self.model.dropped = dropped()
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
final class RecordingHUDModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var dropped = 0
    @Published var isPaused = false
}

private struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    let onStop: () -> Void
    let onPauseResume: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Circle()
                .fill(model.isPaused ? Color.secondary : Color.red)
                .frame(width: 10, height: 10)

            // Recorded time, not wall-clock: a paused recording must not look like it is running.
            Text(Self.clock(model.elapsed))
                .font(.system(size: Theme.Typography.metric, weight: .medium,
                              design: .monospaced))
                .monospacedDigit()

            if model.dropped > 0 {
                // Shown only when non-zero. Producing a stuttering file in silence is the failure
                // this exists to prevent.
                Text("\(model.dropped) dropped")
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button(action: onPauseResume) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .help(model.isPaused ? "Resume" : "Pause")
            .accessibilityLabel(model.isPaused ? "Resume recording" : "Pause recording")

            Button(action: onStop) {
                Image(systemName: "stop.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .help("Stop")
            .accessibilityLabel("Stop recording")

            Button(action: onDiscard) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .help("Discard this take")
            .accessibilityLabel("Discard this recording")
        }
        .padding(.horizontal, Theme.Space.lg)
        .frame(height: 56)
        .background(.regularMaterial)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
