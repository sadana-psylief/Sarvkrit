import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// Brightness for every connected display, from the menu bar.
///
/// macOS puts the built-in panel's brightness on the keyboard and in Control Center, and gives an
/// external monitor nothing at all — the keys do not reach it, and the only control is a physical
/// button on the monitor's own bezel. This is that control, for whichever displays can be reached.
///
/// How a display is reached differs per display and is not always real brightness; `BrightnessChannel`
/// is where that decision lives, and the panel says which one it landed on when it matters.
final class DisplaysFeature: Feature, ObservableObject {
    let id = "displays"
    let category = FeatureCategory.system
    let title = "Displays"
    let summary = "Set the brightness of every screen"
    let details = """
        Adjusts the brightness of each connected display from the Sarvkrit menu, including \
        externals, which the brightness keys don't reach.

        How far it can go depends on the display. The built-in panel and some Apple externals have \
        a backlight macOS can set directly. Everything else falls back to dimming the picture \
        Sarvkrit sends, which works on any display but can only make it darker than the setting on \
        the monitor itself — the panel says so on any display where that is what is happening.

        Dimming this way is undone the moment the feature is switched off, when Sarvkrit quits, and \
        at the next launch if Sarvkrit was killed while a display was dim.
        """
    let symbolName = "display.2"
    /// Nothing to ask for: reading and setting brightness needs no permission of any kind.
    let requirements: Set<Requirement> = []

    @Published private(set) var displays: [ConnectedDisplay] = []
    /// What each slider shows. Held here rather than read from the display on every redraw — a
    /// `DisplayServices` round trip inside `body` would run on the main thread on every frame of a
    /// drag.
    @Published private(set) var levels: [CGDirectDisplayID: Float] = [:]

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Displays")
    private let control = BrightnessControl()
    private var reconfigurationObserver: NSObjectProtocol?

    init() {
        // Before anything else, and whether or not the feature is switched on: this clears a gamma
        // table left behind by a crash, and only this app knows to look. A user whose screen came
        // back dim after a crash would have no way to connect it to Sarvkrit.
        control.restoreGamma()
    }

    func activate() {
        refresh()
        observeReconfiguration()
    }

    func deactivate() {
        if let reconfigurationObserver {
            NotificationCenter.default.removeObserver(reconfigurationObserver)
            self.reconfigurationObserver = nil
        }
        // Off means off: any display Sarvkrit was dimming goes straight back to what it was.
        control.restoreGamma()
        MainActor.assumeIsolated {
            displays = []
            levels = [:]
        }
    }

    /// Re-reads which displays exist and where their brightness is.
    func refresh() {
        let connected = DisplayList.current()
        var current: [CGDirectDisplayID: Float] = [:]
        for display in connected {
            current[display.id] = control.brightness(of: display)
        }
        MainActor.assumeIsolated {
            displays = connected
            levels = current
        }
    }

    func channel(for display: ConnectedDisplay) -> BrightnessChannel {
        control.channel(for: display)
    }

    func setBrightness(_ value: Float, for display: ConnectedDisplay) {
        control.setBrightness(value, for: display)
        MainActor.assumeIsolated { levels[display.id] = value }
    }

    /// Displays come and go, and a stale list means a slider driving a display that is no longer
    /// there. `NSApplication.didChangeScreenParametersNotification` is the documented signal.
    private func observeReconfiguration() {
        guard reconfigurationObserver == nil else { return }
        reconfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // What a display can do is a property of that display, so the answers have to be
            // thrown away when the set of displays changes.
            self.control.invalidate()
            self.refresh()
        }
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(DisplaysDetailView(feature: self))
    }

    @MainActor
    func trayPanels() -> [TrayPanel] {
        [TrayPanel(id: "displays", title: "Displays", symbolName: "display.2") {
            DisplaysPanelView(feature: self)
        }]
    }
}
