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

        model.sinceWake = 0
        model.isHovered = false

        let frame = ScreenPlacement.screenUnderPointer()?.visibleFrame ?? .zero
        let panel = FloatingPanel(
            contentRect: NSRect(x: frame.midX - 150, y: frame.minY + 40,
                                width: 300, height: 44),
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
        // Sized to its contents rather than to a number picked in advance, and re-centred after,
        // so the pill is as wide as what is in it and no wider.
        if let fitting = panel.contentView?.fittingSize {
            panel.setContentSize(fitting)
            panel.setFrameOrigin(NSPoint(x: frame.midX - fitting.width / 2,
                                         y: frame.minY + 40))
        }
        // **Without this the pill never wakes.** `mouseMoved` is not delivered unless the window
        // asks for it, and SwiftUI's `.onHover` is built on it — the same default that once left
        // the capture overlay with no crosshair. The panel stays non-activating, so hovering it
        // cannot take focus from the app being recorded.
        panel.acceptsMouseMovedEvents = true
        panel.orderFrontRegardless()
        self.panel = panel

        // Built once and updated through the model, not rebuilt per tick: rebuilding the hosting
        // view every second destroys any mouse-down in progress on its own buttons.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.model.elapsed = elapsed()
                self.model.dropped = dropped()
                if !self.model.isHovered { self.model.sinceWake += 0.25 }
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
    /// Seconds since the pill last had a reason to be at full strength.
    @Published var sinceWake: TimeInterval = 0
    @Published var isHovered = false

    var opacity: Double {
        HUDDimming.opacity(sinceWake: sinceWake, isHovered: isHovered,
                           isPaused: isPaused, isWarning: dropped > 0)
    }
}

/// When the recording pill gets out of the way.
///
/// **It sits over the thing being demonstrated**, so at full strength it is in every frame of the
/// finished video. It fades back once the recording is under way and comes straight back when the
/// pointer arrives — stopping must never involve a hunt, which is why it never disappears.
enum HUDDimming {
    /// Visible enough to find at a glance, faint enough not to compete with the demo.
    static let restingOpacity = 0.35
    /// Long enough to read the timer and see that recording actually started.
    static let wakeSeconds: TimeInterval = 4

    static func opacity(sinceWake: TimeInterval, isHovered: Bool = false,
                        isPaused: Bool = false, isWarning: Bool = false) -> Double {
        // A paused recording is where somebody has stepped away and needs to find their way back,
        // and a warning that fades out is not a warning.
        if isHovered || isPaused || isWarning { return 1 }
        return sinceWake < wakeSeconds ? 1 : restingOpacity
    }
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
                .frame(width: 8, height: 8)

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
        .padding(.vertical, Theme.Space.sm)
        // Shaped the way the app's own toast is shaped. Both panels used to end in a bare
        // `.background(.regularMaterial)` with no shape at all, which on a borderless
        // clear-backgrounded panel fills a hard-edged rectangle — the "not really beautiful"
        // report, in one missing argument.
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .opacity(model.opacity)
        .animation(.easeInOut(duration: 0.45), value: model.opacity)
        .onHover { hovering in
            model.isHovered = hovering
            if hovering { model.sinceWake = 0 }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
