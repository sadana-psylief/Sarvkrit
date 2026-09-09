import XCTest
@testable import Sarvkrit

/// Which rectangle the aiming overlay opens with.
///
/// The report this answers is *"if I select an area when recording, it should be like a rectangle
/// already on screen that can be resized, it should always remember the last size."* So there is
/// always a rectangle, and it is last time's whenever last time's still exists.
final class RecordingAreaTests: XCTestCase {

    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testTheRememberedRectIsUsedAsItIs() {
        let remembered = CGRect(x: 300, y: 200, width: 800, height: 450)
        XCTAssertEqual(RecordingArea.seed(remembered: remembered, displays: [primary]), remembered)
    }

    /// `SelectionView.settle` drops a rect that touches no display, so a remembered rect from a
    /// monitor that has since been unplugged would leave the overlay empty — the very thing this
    /// is here to prevent. It has to fall back rather than be passed through.
    func testARectOnAVanishedDisplayFallsBackToTheDefault() {
        let offscreen = CGRect(x: 4000, y: 4000, width: 800, height: 450)
        let seed = RecordingArea.seed(remembered: offscreen, displays: [primary])
        XCTAssertNotEqual(seed, offscreen)
        XCTAssertEqual(seed.map { primary.intersects($0) }, true)
    }

    /// Even the first time. "A rectangle already on screen" is the request, and an empty screen to
    /// drag on is what it is asking not to see.
    func testWithNothingRememberedThereIsStillARectangle() {
        guard let seed = RecordingArea.seed(remembered: nil, displays: [primary]) else {
            return XCTFail("the first area recording still needs something to resize")
        }
        XCTAssertTrue(primary.contains(seed))
        XCTAssertGreaterThan(seed.width, 0)
        XCTAssertGreaterThan(seed.height, 0)
    }

    func testTheDefaultIsCentredOnTheDisplay() {
        guard let seed = RecordingArea.seed(remembered: nil, displays: [primary]) else {
            return XCTFail("no seed")
        }
        XCTAssertEqual(seed.midX, primary.midX, accuracy: 0.5)
        XCTAssertEqual(seed.midY, primary.midY, accuracy: 0.5)
    }

    /// A 16:9 default, because that is the shape of everything it will be exported into.
    func testTheDefaultIsWidescreen() {
        guard let seed = RecordingArea.seed(remembered: nil, displays: [primary]) else {
            return XCTFail("no seed")
        }
        XCTAssertEqual(seed.width / seed.height, 16.0 / 9.0, accuracy: 0.01)
    }

    /// A tall or tiny display must not produce a box hanging off the edge, where two of its
    /// handles cannot be reached.
    func testTheDefaultFitsATallDisplay() {
        let tall = CGRect(x: 0, y: 0, width: 900, height: 1600)
        guard let seed = RecordingArea.seed(remembered: nil, displays: [tall]) else {
            return XCTFail("no seed")
        }
        XCTAssertTrue(tall.contains(seed), "\(seed) escaped \(tall)")
    }

    /// A display to the left of the primary has a negative origin, and that is not an error state.
    func testTheDefaultFollowsANegativeOrigin() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        guard let seed = RecordingArea.seed(remembered: nil, displays: [left]) else {
            return XCTFail("no seed")
        }
        XCTAssertTrue(left.contains(seed), "\(seed) escaped \(left)")
    }

    func testWithNoDisplaysThereIsNothingToSeed() {
        XCTAssertNil(RecordingArea.seed(remembered: nil, displays: []))
    }
}
