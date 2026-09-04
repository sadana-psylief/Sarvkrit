import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// Lays out every panel in the menu bar strip.
///
/// The panel is a `MenuBarExtra` window, which means it cannot be opened without a real click on a
/// real status item — so nothing else in the suite ever sees it. These tests prove each panel
/// builds and lays out, in both appearances, against the data shapes that are actually hard: no
/// samples at all, a history that is entirely gaps, nothing playing.
///
/// Set `SARVKRIT_PREVIEW_DIR` to also write a PNG per panel, which is how the layout gets looked at
/// rather than merely asserted about.
@MainActor
final class TrayPanelRenderTests: XCTestCase {

    /// Renders in a real window, parked far off any screen.
    ///
    /// Two simpler things were tried first and both lie about what these panels look like:
    ///
    /// - A windowless `NSHostingView` + `cacheDisplay` draws explicit colours and nothing else.
    ///   Every semantic style — `.primary`, `.secondary`, `.quaternary`, `.separator` — resolves to
    ///   transparent with no appearance context to resolve against, and semantic colour is the
    ///   house style, so the result was one accent-tinted tab on white.
    /// - `ImageRenderer` resolves those correctly but cannot draw an AppKit-backed control, and
    ///   `Tokens.swift`'s first rule is never to hand-roll a control AppKit provides. Every switch
    ///   and slider came out as a placeholder block — holes exactly where the controls are.
    ///
    /// A real window has both: a backing store for the styles and real `NSView`s for the switches.
    /// It is placed at -30000 so it is on no display, and closed in `defer`, so nothing can be
    /// stranded on screen even if an assertion throws.
    private func snapshot(_ view: some View, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view
                .environmentObject(AppState.shared)
                .frame(width: Theme.Size.dropdownWidth)
                // The panel's own backdrop. `MenuBarExtra` supplies one in the real thing; here
                // the window is clear, and a panel drawn on nothing is unreadable.
                .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
        )
        // Height comes from the content, never from the caller. Imposing one reproduced nothing
        // the user would ever see: the real panel is sized to its content by
        // `MenuBarWindowAnchor`, and a fixed frame instead let a tall panel draw straight over the
        // menu rows beneath it — an overlap that exists only in a bitmap nobody resized.
        let size = CGSize(width: Theme.Size.dropdownWidth,
                          height: max(1, host.fittingSize.height))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000),
                                                  size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()

        // `MenuBarView` resolves its selection in `onAppear`, which lands *after* the first layout
        // pass. Capturing there caught a half-updated frame: the new panel's content drawn inside
        // the old panel's height, overlapping the rows beneath it. Letting the run loop turn is
        // what makes the bitmap show a settled view rather than a transitional one.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        // Re-measure: resolving the selection can swap in a taller panel than the one that was
        // measured a moment ago.
        let settled = CGSize(width: size.width, height: max(1, host.fittingSize.height))
        window.setContentSize(settled)
        host.frame = CGRect(origin: .zero, size: settled)
        host.layoutSubtreeIfNeeded()
        // `display()`, not `displayIfNeeded()`. The window's backing store survives the selection
        // resolving, and a partial redraw left the previous panel's tab highlight and section
        // header still painted underneath the new one — two tabs looking selected at once, in a
        // bitmap and never in the app.
        window.display()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SARVKRIT_PREVIEW_DIR"]
        else { return }
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private var keepAwake: KeepAwakeFeature {
        AppState.shared.features.compactMap { $0 as? KeepAwakeFeature }.first!
    }

    /// Every panel the registry can contribute, whether or not its feature is currently on — the
    /// point is that each one lays out, not that this Mac happens to have it switched on.
    private var allPanels: [TrayPanel] {
        TrayPanel.merged(AppState.shared.features.flatMap { $0.trayPanels() })
    }

    func testEveryContributedPanelLaysOut() throws {
        for panel in allPanels {
            for scheme in [ColorScheme.light, .dark] {
                let rep = try snapshot(
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        SectionHeader(panel.title)
                        panel.content()
                    }
                    .padding(Theme.Space.md),
                                   scheme: scheme)
                XCTAssertGreaterThan(rep.pixelsWide, 0, panel.id)
                try write(rep, named: "panel-\(panel.id)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testTheFeaturesPanelLaysOutWithEverySwitchInIt() throws {
        // The tallest thing in the app by some margin — eighteen rows and seven headers — and the
        // one panel that has to scroll rather than grow.
        for scheme in [ColorScheme.light, .dark] {
            let rep = try snapshot(FeaturesPanelView().padding(Theme.Space.md),
                                   scheme: scheme)
            XCTAssertGreaterThan(rep.pixelsHigh, 0)
            try write(rep, named: "panel-features-\(scheme == .dark ? "dark" : "light")")
        }
    }

    func testTheStripLaysOutWithEveryPanelOnIt() throws {
        // Nine icons at a fixed 34pt square have to fit the panel's width with room to spare; the
        // width stopped being a function of the tab count when the labels went, and this is what
        // would notice if a tenth panel ever changed that.
        let panels = allPanels + [
            TrayPanel(id: TrayPanel.featuresID, title: "Features", symbolName: "switch.2") {
                EmptyView()
            },
            TrayPanel(id: TrayPanel.generalID, title: "General", symbolName: "gearshape") {
                EmptyView()
            },
        ]
        for scheme in [ColorScheme.light, .dark] {
            let rep = try snapshot(
                TrayPanelStrip(panels: panels, selection: .constant("system"))
                    .padding(Theme.Space.md),
                                   scheme: scheme)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            try write(rep, named: "strip-\(scheme == .dark ? "dark" : "light")")
        }
    }

    func testTheWholePanelLaysOut() throws {
        let restore = AppState.shared.selectedTrayTabID
        defer { AppState.shared.selectedTrayTabID = restore }

        for id in ["keep-awake", "sound", "system", "network", "disks", "power",
                   TrayPanel.featuresID, TrayPanel.generalID] {
            AppState.shared.selectedTrayTabID = id
            for scheme in [ColorScheme.light, .dark] {
                let rep = try snapshot(MenuBarView(keepAwakeFeature: keepAwake),
                                   scheme: scheme)
                XCTAssertGreaterThan(rep.pixelsWide, 0)
                try write(rep, named: "menu-\(id)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    /// A monitor that has actually sampled this Mac, three times, so rates and history exist.
    ///
    /// Every rate is `nil` on the first sample — a rate needs two — so a panel rendered against a
    /// fresh feature is all dashes, which says nothing about whether real numbers fit their
    /// columns. This is the only way the previews show what a user sees.
    private func sampledMonitor() -> SystemMonitorFeature {
        let feature = SystemMonitorFeature(defaults: UserDefaults(suiteName: "preview.\(UUID())")!)
        feature.enabledMetrics = Set(MetricKind.allCases)
        for _ in 0..<3 {
            feature.apply(feature.takeSnapshot())
            // Real elapsed time: a rate over a zero interval is discarded by design.
            Thread.sleep(forTimeInterval: 0.4)
        }
        return feature
    }

    private func monitorPanels(_ feature: SystemMonitorFeature) -> [(String, AnyView)] {
        [
            ("system", AnyView(SystemPanelView(feature: feature))),
            ("network", AnyView(NetworkPanelView(feature: feature))),
            ("disks", AnyView(DisksPanelView(feature: feature))),
            ("power", AnyView(PowerPanelView(feature: feature))),
        ]
    }

    func testTheMonitorPanelsRenderAgainstRealReadings() throws {
        let feature = sampledMonitor()
        for (name, view) in monitorPanels(feature) {
            for scheme in [ColorScheme.light, .dark] {
                let rep = try snapshot(
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        SectionHeader(name)
                        view
                    }
                    .padding(Theme.Space.md),
                    scheme: scheme)
                XCTAssertGreaterThan(rep.pixelsHigh, 0, name)
                try write(rep, named: "live-\(name)-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testTheDisplaysPanelRendersTheRealDisplays() throws {
        // The feature lists nothing until it is switched on, so a panel rendered against a fresh
        // one says only that the empty state lays out. This is the populated path.
        let feature = DisplaysFeature()
        feature.activate()
        defer { feature.deactivate() }
        XCTAssertFalse(feature.displays.isEmpty, "this Mac has at least one display")

        for scheme in [ColorScheme.light, .dark] {
            let rep = try snapshot(
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    SectionHeader("Displays")
                    DisplaysPanelView(feature: feature)
                }
                .padding(Theme.Space.md),
                scheme: scheme)
            XCTAssertGreaterThan(rep.pixelsHigh, 0)
            try write(rep, named: "live-displays-\(scheme == .dark ? "dark" : "light")")
        }
    }

    func testEveryMonitorPanelSurvivesAHistoryThatIsEntirelyGaps() throws {
        // The NaN-shaped case `SystemMonitorPaneRenderTests` pins for the window's pane: an all-gap
        // window is an empty y-domain, and a chart handed one draws nothing or crashes. All four
        // panels draw charts, so all four are exposed to it.
        let feature = AppState.shared.features.compactMap { $0 as? SystemMonitorFeature }.first!
        for (name, view) in monitorPanels(feature) {
            XCTAssertGreaterThan(try snapshot(view, scheme: .dark).pixelsHigh, 0, name)
        }
    }
}
