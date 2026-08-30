import SwiftUI

@main
struct SarvkritApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    init() {
        // Before any scene exists, so a duplicate launch never puts a second icon in the menu
        // bar — not even briefly. This call does not return if another Sarvkrit is running.
        MainActor.assumeIsolated { SingleInstance.yieldIfAlreadyRunning() }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $state.showMenuBarIcon) {
            if let keepAwake = state.features.compactMap({ $0 as? KeepAwakeFeature }).first {
                MenuBarView(keepAwakeFeature: keepAwake).environmentObject(state)
            }
        } label: {
            // Template rendering is what makes the icon invert correctly in light and dark
            // menu bars and dim when the menu bar is inactive. Never ship a coloured one.
            if let keepAwake = state.features.compactMap({ $0 as? KeepAwakeFeature }).first {
                MenuBarLabel(keepAwake: keepAwake)
            } else {
                Image(systemName: MenuBarIconState.idle.symbolName)
            }
        }
        // A window, not an NSMenu: NSMenu can't host live switches.
        .menuBarExtraStyle(.window)
    }
}
