import XCTest
@testable import Sarvkrit

/// The feature's lifecycle, with a stubbed SMC.
///
/// Nothing here opens a real user client: the sampler is injected, so every case below — a
/// fanless Mac, an SMC that will not answer — is reachable on the machine running the suite.
@MainActor
final class FanControlFeatureTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "fanControl.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Counts how many times the SMC was asked anything, so "nothing runs until you switch it on"
    /// is an assertion rather than a claim.
    private final class ReadCounter {
        private(set) var reads = 0
        var values: [String: Double]
        init(_ values: [String: Double]) { self.values = values }
        func read(_ key: SMCKey) -> Double? {
            reads += 1
            return values[key.description]
        }
    }

    private func feature(_ counter: ReadCounter) -> FanControlFeature {
        FanControlFeature(defaults: defaults, makeSampler: { FanSampler(read: counter.read) })
    }

    private func settle() {
        let done = expectation(description: "sample lands")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// `FeatureRegistry.makeAll()` builds every feature at launch regardless of its toggle, so an
    /// init that touched the SMC would poll on a Mac where the feature is switched off.
    func testConstructingTheFeatureTouchesNothing() {
        let counter = ReadCounter(["FNum": 2])
        _ = feature(counter)
        XCTAssertEqual(counter.reads, 0)
    }

    /// The protocol's default is `[.accessibility]`. Inheriting it would gate a feature that
    /// reads a coprocessor behind a grant it has no use for.
    func testTheFeatureNeedsNoPermissions() {
        XCTAssertTrue(feature(ReadCounter([:])).requirements.isEmpty)
    }

    func testSwitchingItOnReadsTheFans() {
        let counter = ReadCounter(["FNum": 2, "F0Ac": 2400, "F0Mn": 2317, "F0Mx": 6800])
        let feature = feature(counter)
        feature.activate()
        settle()

        guard case let .fans(fans) = feature.hardware else { return XCTFail("expected fans") }
        XCTAssertEqual(fans.count, 2)
        XCTAssertEqual(fans[0].rpm, 2400)
        feature.deactivate()
    }

    /// Off means off: the panel must not go on showing the last thing it saw.
    func testSwitchingItOffForgetsWhatItSaw() {
        let feature = feature(ReadCounter(["FNum": 1, "F0Ac": 2400]))
        feature.activate()
        settle()
        feature.deactivate()

        XCTAssertEqual(feature.hardware, .unreadable)
        XCTAssertFalse(feature.isRunning)
    }

    /// `AppState.deinit` calls `deactivate()` on everything, including features that were never on.
    func testDeactivatingSomethingThatWasNeverOnIsHarmless() {
        let feature = feature(ReadCounter([:]))
        feature.deactivate()
        feature.deactivate()
        XCTAssertFalse(feature.isRunning)
    }

    /// A MacBook Air has nothing to poll. Sampling it every two seconds forever would be pure
    /// cost for a panel that can only ever say the same sentence.
    func testAFanlessMacIsPolledOnceAndThenLeftAlone() {
        let counter = ReadCounter(["FNum": 0])
        let feature = feature(counter)
        feature.activate()
        settle()

        XCTAssertEqual(feature.hardware, .fanless)
        XCTAssertFalse(feature.isPolling, "a fanless Mac should not be on a timer")
        feature.deactivate()
    }

    func testItContributesOneFansTab() {
        let panels = feature(ReadCounter([:])).trayPanels()
        XCTAssertEqual(panels.map(\.id), ["fans"])
        XCTAssertEqual(panels.first?.title, "Fans")
    }

    func testItHasItsOwnDetailPane() {
        XCTAssertNotNil(feature(ReadCounter([:])).makeDetailView())
    }
}
