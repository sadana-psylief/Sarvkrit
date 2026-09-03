import SwiftUI

@main
struct SarvkritApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    /// Resolved once, in `init`, rather than looked up inside the scene builder.
    ///
    /// `SceneBuilder` cannot express "no scene at all", so the monitor's `MenuBarExtra` has to be
    /// declared unconditionally and needs a non-optional feature. `monitorIsRegistered` is what
    /// actually keeps the item out of the menu bar if the registry ever stops including it — the
    /// fallback instance is never activated, and never inserted.
    private let monitor: SystemMonitorFeature
    private let monitorIsRegistered: Bool

    init() {
        // Before any scene exists, so a duplicate launch never puts a second icon in the menu
        // bar — not even briefly. This call does not return if another Sarvkrit is running.
        MainActor.assumeIsolated { SingleInstance.yieldIfAlreadyRunning() }

        let found = AppState.shared.features.compactMap { $0 as? SystemMonitorFeature }.first
        monitorIsRegistered = found != nil
        monitor = found ?? SystemMonitorFeature()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $state.showMenuBarIcon) {
            if let keepAwake = state.features.compactMap({ $0 as? KeepAwakeFeature }).first {
                MenuBarView(keepAwakeFeature: keepAwake).environmentObject(state)
            }
        } label: {
            // Template rendering is what makes the icon invert correctly in light and dark
            // menu bars and dim when the menu bar is inactive. Never ship a coloured one.
            // Both features are handed in directly rather than reached through AppState: SwiftUI
            // doesn't observe through a nested ObservableObject, so an icon routed that way would
            // change only on some unrelated redraw — and an indicator you can't rely on noticing is
            // worse than none.
            if let keepAwake = state.features.compactMap({ $0 as? KeepAwakeFeature }).first,
               let micMute = state.features.compactMap({ $0 as? MuteMicrophoneFeature }).first,
               let privacy = state.features.compactMap({ $0 as? PrivacyGuardFeature }).first {
                MenuBarLabel(keepAwake: keepAwake, micMute: micMute, privacy: privacy)
            } else {
                Image(systemName: MenuBarIconState.idle.symbolName)
            }
        }
        // A window, not an NSMenu: NSMenu can't host live switches.
        .menuBarExtraStyle(.window)

        monitorScene
    }

    /// The monitor's own menu bar item.
    ///
    /// A second item rather than more content in the first. The existing label is a single template
    /// symbol arbitrated by `MenuBarIconState`'s precedence chain — "the more consequential state
    /// wins" — and a live numeric readout has no place in a chain that shows exactly one thing.
    /// Folding it in would mean either losing the readout whenever the microphone is muted, or
    /// losing the microphone warning whenever the monitor is on.
    ///
    /// Held as its own property because the scene builder could not type-check it inline.
    private var monitorScene: some Scene {
        // `isInserted` depends only on state AppState publishes, because that is the only thing
        // this body observes — see SystemMonitorMenuBar, which carries the reasoning and the tests.
        //
        // The setter is deliberately inert. `get` is derived from two other settings, and SwiftUI
        // writes back through two-way bindings as an ordinary part of an update pass; honouring a
        // write-back of `false` would switch the whole feature off as a side effect of hiding the
        // app's menu bar icon.
        MenuBarExtra(isInserted: Binding(
            get: {
                monitorIsRegistered && SystemMonitorMenuBar.isInserted(
                    showsAppIcon: state.showMenuBarIcon,
                    featureIsEnabled: state.isEnabled(monitor)
                )
            },
            set: { _ in }
        )) {
            SystemMonitorTrayView(feature: monitor).environmentObject(state)
        } label: {
            // Observed directly, not through AppState: nested ObservableObject changes don't
            // propagate, so a readout routed that way would move only on unrelated redraws.
            SystemMonitorMenuBarLabel(feature: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
