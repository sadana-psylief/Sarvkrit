import SwiftUI
import XCTest
@testable import Sarvkrit

/// Mounts the menu bar label with the four features that now share it.
///
/// **This cannot check the thing most likely to break.** A `MenuBarExtra` label renders exactly one
/// `Image` and one `Text` and silently drops the rest, and that limit lives in the status item, not
/// in SwiftUI — an `NSHostingView` will happily lay out a label the menu bar would render as half
/// of itself. So this guards construction and layout only; the real check is looking at the menu
/// bar, and there is a step for it in the plan.
///
/// What it does catch is the registry drifting: all four features are pulled from
/// `FeatureRegistry.makeAll()`, so removing or renaming one fails here rather than silently
/// falling back to the plain icon in `SarvkritApp`.
@MainActor
final class MenuBarLabelRenderTests: XCTestCase {

    private func makeLabel() throws -> MenuBarLabel {
        let features = FeatureRegistry.makeAll()
        return MenuBarLabel(
            keepAwake: try XCTUnwrap(features.compactMap { $0 as? KeepAwakeFeature }.first),
            micMute: try XCTUnwrap(features.compactMap { $0 as? MuteMicrophoneFeature }.first),
            privacy: try XCTUnwrap(features.compactMap { $0 as? PrivacyGuardFeature }.first),
            monitor: try XCTUnwrap(
                features.compactMap { $0 as? SystemMonitorFeature }.first,
                "SarvkritApp falls back to a bare icon unless every one of these is registered"
            )
        )
    }

    func testTheLabelLaysOutWithNothingToSay() throws {
        let view = NSHostingView(rootView: try makeLabel())
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.width, 0)
    }

    func testTheLabelLaysOutWithLiveReadings() throws {
        let features = FeatureRegistry.makeAll()
        // Registry drift is caught by `makeLabel()` and the test above. This one needs a monitor
        // with something to *say*, and which metrics appear beside the icon is a user preference
        // — so it reads from an empty suite and gets the defaults, rather than from the
        // developer's own. Whoever runs this may well have turned every readout off in the real
        // app, which left `menuBarLine` empty and failed the precondition below on their machine
        // and nowhere else.
        XCTAssertNotNil(features.compactMap { $0 as? SystemMonitorFeature }.first,
                        "SarvkritApp falls back to a bare icon unless this is registered")
        let suite = "MenuBarLabelRenderTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = SystemMonitorFeature(defaults: defaults)
        // Activated on purpose: a monitor that is switched off contributes nothing to the label,
        // by design, so there would be no live readings to lay out.
        monitor.activate()
        defer { monitor.deactivate() }
        monitor.apply(SystemSnapshot(cpu: CPUSample(usage: 42, coreCount: 10)))
        XCTAssertFalse(monitor.menuBarLine.isEmpty, "precondition: there is something to render")

        let view = NSHostingView(rootView: MenuBarLabel(
            keepAwake: try XCTUnwrap(features.compactMap { $0 as? KeepAwakeFeature }.first),
            micMute: try XCTUnwrap(features.compactMap { $0 as? MuteMicrophoneFeature }.first),
            privacy: try XCTUnwrap(features.compactMap { $0 as? PrivacyGuardFeature }.first),
            monitor: monitor
        ))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.width, 0)
    }
}
