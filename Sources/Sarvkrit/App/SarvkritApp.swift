import SwiftUI

@main
struct SarvkritApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $state.showMenuBarIcon) {
            if let keepAwake = state.features.compactMap({ $0 as? KeepAwakeFeature }).first {
                MenuBarView(keepAwakeFeature: keepAwake).environmentObject(state)
            }
        } label: {
            // Template rendering is what makes the icon invert correctly in light and dark
            // menu bars and dim when the menu bar is inactive. Never ship a coloured one.
            // Every feature is handed in directly rather than reached through AppState: SwiftUI
            // doesn't observe through a nested ObservableObject, so an icon routed that way would
            // change only on some unrelated redraw — and an indicator you can't rely on noticing is
            // worse than none.
            //
            // The System Monitor is here for its readings, not the icon. It adds no status item of
            // its own: Sarvkrit is one menu bar icon, and MenuBarLabel composes the countdown and
            // the readings into the single text slot a MenuBarExtra label can actually render.
            if let keepAwake = state.features.compactMap({ $0 as? KeepAwakeFeature }).first,
               let micMute = state.features.compactMap({ $0 as? MuteMicrophoneFeature }).first,
               let privacy = state.features.compactMap({ $0 as? PrivacyGuardFeature }).first,
               let monitor = state.features.compactMap({ $0 as? SystemMonitorFeature }).first {
                MenuBarLabel(
                    keepAwake: keepAwake, micMute: micMute, privacy: privacy, monitor: monitor)
            } else {
                Image(systemName: MenuBarIconState.idle.symbolName)
            }
        }
        // A window, not an NSMenu: NSMenu can't host live switches.
        .menuBarExtraStyle(.window)
    }
}
