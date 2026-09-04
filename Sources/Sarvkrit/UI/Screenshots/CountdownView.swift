import AppKit
import SwiftUI

/// The self-timer countdown, shown over the screen it is about to capture.
struct CountdownView: View {
    let secondsLeft: Int

    var body: some View {
        Text("\(secondsLeft)")
            .font(.system(size: 72, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 140, height: 140)
            .background(.black.opacity(0.55), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            // Announced rather than silent: an accessory app counting down invisibly to a
            // screenshot is exactly the kind of thing a screen reader user needs told.
            .accessibilityLabel("\(secondsLeft) seconds until capture")
    }
}

/// Shows the countdown in the middle of the screen the pointer is on, then calls back.
///
/// A `FloatingPanel` at status-bar level with clicks passing through: the point of the timer is
/// to arrange the screen during it, so the countdown must not be in the way of doing that.
@MainActor
final class CountdownPresenter {
    static let shared = CountdownPresenter()

    private var panel: FloatingPanel?
    private var timer: Timer?

    func run(seconds: Int, completion: @escaping (Bool) -> Void) {
        cancel()
        guard seconds > 0 else { completion(true); return }

        let size = CGSize(width: 140, height: 140)
        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = FloatingPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2,
                                y: visible.midY - size.height / 2,
                                width: size.width, height: size.height),
            style: .init(level: .statusBar, acceptsKey: false,
                         // Clicks pass through: the user is arranging the screen during the
                         // countdown, and a HUD that swallowed those clicks would defeat it.
                         clickThrough: true,
                         joinsAllSpaces: true, hasShadow: false))
        self.panel = panel

        let startedAt = Date()
        let duration = TimeInterval(seconds)
        panel.contentView = NSHostingView(rootView: CountdownView(secondsLeft: seconds))
        panel.orderFrontRegardless()

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                switch Countdown.state(now: Date(), startedAt: startedAt, duration: duration) {
                case .counting(let left):
                    panel.contentView = NSHostingView(rootView: CountdownView(secondsLeft: left))
                case .fired:
                    self.cancel()
                    completion(true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
