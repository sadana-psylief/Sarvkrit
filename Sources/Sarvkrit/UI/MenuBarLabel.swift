import SwiftUI

/// The menu bar icon, and whatever text belongs beside it.
///
/// **The label renders exactly one `Image` and one `Text`.** That is a hard `MenuBarExtra` limit,
/// not a style choice: a second `Image` or `Text` in here produces no error, no warning and no
/// pixels — it is simply dropped. Inline images inside a concatenated `Text` are dropped too. Both
/// were tried against the real menu bar. Four features now share this one slot, so anything new
/// that wants to appear beside the icon has to be composed into the single string that
/// `MenuBarIconState.trailingText` builds.
///
/// Every feature is held as an `@ObservedObject` **directly**, rather than reached through
/// `AppState`. SwiftUI does not observe through a nested `ObservableObject` — that's the bug that
/// left the onboarding checkmark refusing to update and later froze the feature toggles. Routing
/// this through `AppState` would produce an icon that changed only on some unrelated redraw.
///
/// That distinction is worth stating precisely, because it cuts both ways and this app keeps
/// relearning it: state driving `MenuBarExtra(isInserted:)` in `SarvkritApp.body` **must** be
/// published by `AppState`, since that body observes nothing else — but state driving what a
/// directly-observed view like this one *renders* may live on the feature. The System Monitor's
/// "show live data" switch is the second kind, which is why it can be a feature setting.
struct MenuBarLabel: View {
    @ObservedObject var keepAwake: KeepAwakeFeature
    /// Observed directly for the same reason as Keep Awake — an icon that only updated on some
    /// unrelated redraw would be worse than no indicator, since the whole point is noticing.
    @ObservedObject var micMute: MuteMicrophoneFeature
    /// Observed directly for the same reason as the others — an indicator that only updated on some
    /// unrelated redraw would defeat the whole point of having one.
    @ObservedObject var privacy: PrivacyGuardFeature
    /// Observed directly so each sample it publishes moves the numbers. This is also why the
    /// monitor needs no ticker here: unlike the countdown, its value arrives already published.
    @ObservedObject var monitor: SystemMonitorFeature

    /// Re-read only while a countdown is running, and only twice a minute: minute resolution needs
    /// nothing finer, and a per-second timer in the menu bar is exactly the idle cost this app has
    /// spent effort removing.
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            // Template-rendered, so it inverts on light and dark menu bars and dims when the menu
            // bar is inactive — which a coloured icon would not.
            Image(systemName: state.symbolName)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    // Proportional digits change the item's width on almost every sample, which
                    // shoves every item to the left of this one along with it.
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .onReceive(tick) { instant in
            // Only churn the view while there's actually a countdown to move. The monitor's own
            // readings are published by the feature and need nothing from this timer.
            guard keepAwake.remainingTime != nil else { return }
            now = instant
        }
    }

    /// A muted microphone outranks the sleep states — see `MenuBarIconState.current`.
    private var state: MenuBarIconState {
        MenuBarIconState.current(
            keepAwakeRunning: keepAwake.isRunning,
            systemSleepDisabled: keepAwake.systemSleepDisabled,
            microphoneMuted: micMute.isMuted || privacy.isMicrophoneMuted,
            cameraOn: privacy.isCameraOn
        )
    }

    /// The one text slot's contents: the Keep Awake countdown and the monitor's readings, composed.
    private var trailing: String? {
        MenuBarIconState.trailingText(countdown: countdown, liveData: monitor.menuBarLine)
    }

    private var countdown: String? {
        MenuBarIconState.countdownText(remaining: keepAwake.remainingTime)
    }

    private var accessibilityLabel: String {
        guard let trailing else { return state.accessibilityLabel }
        return "\(state.accessibilityLabel), \(trailing)"
    }
}
