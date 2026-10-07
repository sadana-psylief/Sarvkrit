import XCTest
@testable import Sarvkrit

final class FanRegistryTests: XCTestCase {
    /// The id is the UserDefaults key. Renaming it silently resets everyone's choice.
    func testFanControlIsRegisteredUnderAStableID() {
        let ids = FeatureRegistry.makeAll().map(\.id)
        XCTAssertTrue(ids.contains("fan-control"), "fan control is missing from the registry")
    }

    func testFanControlSitsWithTheOtherSystemFeatures() {
        let feature = FeatureRegistry.makeAll().first { $0.id == "fan-control" }
        XCTAssertEqual(feature?.category, .system)
    }
}
