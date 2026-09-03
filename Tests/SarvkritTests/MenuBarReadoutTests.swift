import XCTest
@testable import Sarvkrit

/// What the second menu bar item actually says.
///
/// This is `MenuBarIconState`'s counterpart for the monitor: the arrangement decision pulled out of
/// the view so it can be asserted rather than squinted at. The menu bar is unforgiving — segments
/// that appear and vanish shove every other item along, and a readout whose order drifts between
/// redraws is unreadable at a glance — so both are pinned here.
final class MenuBarReadoutTests: XCTestCase {

    private var busy: SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpu = CPUSample(usage: 42, coreCount: 10)
        snapshot.memory = MemorySample(used: 9_878_424_780, total: 17_179_869_184)
        snapshot.network = NetworkSample(downloadPerSecond: 3_250_586, uploadPerSecond: 419_430)
        snapshot.battery = BatterySample(percent: 87, isCharging: false, isPresent: true)
        return snapshot
    }

    // MARK: - Order

    func testSegmentsFollowTheUsersChosenOrderNotDeclarationOrder() {
        // The pane lets someone put battery first. Falling back to `MetricKind.allCases` order
        // would silently ignore that, and the setting would look broken rather than unimplemented.
        let segments = MenuBarReadout.segments(for: busy, metrics: [.battery, .cpu])
        XCTAssertEqual(segments.map(\.text), ["87%", "42%"])
    }

    func testChoosingNothingShowsNoSegments() {
        // An empty selection is legitimate: it means "just the icon, no numbers".
        XCTAssertTrue(MenuBarReadout.segments(for: busy, metrics: []).isEmpty)
    }

    func testARepeatedMetricAppearsOnce() {
        // Defensive against a persisted list that picked up a duplicate; the same number twice in
        // the menu bar is pure noise.
        let segments = MenuBarReadout.segments(for: busy, metrics: [.cpu, .cpu])
        XCTAssertEqual(segments.count, 1)
    }

    // MARK: - What each metric contributes

    func testCPUAndMemoryReadAsPercentages() {
        XCTAssertEqual(MenuBarReadout.segments(for: busy, metrics: [.cpu]).first?.text, "42%")
        // Memory as a share of installed RAM, not an absolute — 9.2 of 16 GB is 57%, and the
        // absolute figure needs three more characters to say less.
        XCTAssertEqual(MenuBarReadout.segments(for: busy, metrics: [.memory]).first?.text, "57%")
    }

    func testNetworkShowsTheDownloadRate() {
        // One direction only. Both would double the width of the widest segment for a number most
        // people glance at to answer "is something downloading".
        XCTAssertEqual(
            MenuBarReadout.segments(for: busy, metrics: [.network]).first?.text, "3.1 MB/s")
    }

    func testEverySegmentCarriesADistinctSymbol() {
        // The symbol is what makes an unlabelled number identifiable at a glance; two metrics
        // sharing one would make the readout ambiguous.
        let segments = MenuBarReadout.segments(for: busy, metrics: MetricKind.allCases)
        XCTAssertEqual(Set(segments.map(\.symbolName)).count, segments.count)
    }

    // MARK: - Missing readings

    func testAMetricWithNoReadingKeepsItsPlaceAsAPlaceholder() {
        // Dropping the segment instead would reflow the whole menu bar every time a rate is
        // briefly unavailable — which happens on every wake, by design.
        let segments = MenuBarReadout.segments(for: SystemSnapshot(), metrics: [.cpu, .network])
        XCTAssertEqual(segments.map(\.text), ["—", "—"])
        XCTAssertEqual(segments.count, 2, "a missing reading must not collapse the layout")
    }

    func testAMachineWithNoBatteryStillRendersAPlaceholder() {
        // Desktops report no power source. That is normal, and must not read as 0%.
        var snapshot = SystemSnapshot()
        snapshot.battery = BatterySample(percent: 0, isCharging: false, isPresent: false)
        XCTAssertEqual(MenuBarReadout.segments(for: snapshot, metrics: [.battery]).first?.text, "—")
    }

    // MARK: - MetricKind itself

    func testEveryMetricKindHasATitleAndASymbol() {
        for kind in MetricKind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind.rawValue) has no title")
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind.rawValue) has no symbol")
        }
    }

    func testMetricKindRawValuesAreStable() {
        // These are persisted in the enabled-metrics setting. Renaming one silently resets the
        // user's choice, exactly as renaming a feature id would.
        XCTAssertEqual(
            MetricKind.allCases.map(\.rawValue),
            ["cpu", "gpu", "power", "battery", "memory", "disk", "network"]
        )
    }
}
