import SwiftUI

/// The menu bar icon, reflecting whether the Mac can currently sleep.
///
/// Holds `KeepAwakeFeature` as an `@ObservedObject` **directly**, rather than reaching through
/// `AppState`. SwiftUI does not observe through a nested `ObservableObject` — that's the bug that
/// left the onboarding checkmark refusing to update and later froze the feature toggles. Routing
/// this through `AppState` would produce an icon that changed only on some unrelated redraw.
struct MenuBarLabel: View {
    @ObservedObject var keepAwake: KeepAwakeFeature
    /// Observed directly for the same reason as Keep Awake — an icon that only updated on some
    /// unrelated redraw would be worse than no indicator, since the whole point is noticing.
    @ObservedObject var micMute: MuteMicrophoneFeature

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
            if let countdown {
                Text(countdown).font(.system(size: 11, weight: .medium))
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .onReceive(tick) { instant in
            // Only churn the view while there's actually a countdown to move.
            guard keepAwake.remainingTime != nil else { return }
            now = instant
        }
    }

    /// A muted microphone outranks the sleep states — see `MenuBarIconState.current`.
    private var state: MenuBarIconState {
        MenuBarIconState.current(
            keepAwakeRunning: keepAwake.isRunning,
            systemSleepDisabled: keepAwake.systemSleepDisabled,
            microphoneMuted: micMute.isMuted
        )
    }

    private var countdown: String? {
        MenuBarIconState.countdownText(remaining: keepAwake.remainingTime)
    }

    private var accessibilityLabel: String {
        guard let countdown else { return state.accessibilityLabel }
        return "\(state.accessibilityLabel), \(countdown) remaining"
    }
}
