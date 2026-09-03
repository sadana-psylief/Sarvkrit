import XCTest
@testable import Sarvkrit

final class CaptureModeMemoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    func testTheLastModeSurvivesARoundTrip() {
        CaptureModeMemory(mode: .window, pixelSize: CGSize(width: 800, height: 600),
                          aspectLocked: true).save(to: defaults)
        let loaded = CaptureModeMemory.load(from: defaults)
        XCTAssertEqual(loaded.mode, .window)
        XCTAssertEqual(loaded.pixelSize, CGSize(width: 800, height: 600))
        XCTAssertTrue(loaded.aspectLocked)
    }

    func testNothingStoredFallsBackToArea() {
        XCTAssertEqual(CaptureModeMemory.load(from: defaults), .fallback)
    }

    func testAModeThatNoLongerExistsFallsBackRatherThanCrashing() {
        // Real: a mode removed in a later version leaves its raw value behind in a UserDefaults
        // that outlives the build that wrote it.
        defaults.set("holographic", forKey: "screenshot.lastMode")
        XCTAssertEqual(CaptureModeMemory.load(from: defaults).mode, .area)
    }

    func testAFreehandSelectionClearsTheRememberedSize() {
        CaptureModeMemory(mode: .area, pixelSize: CGSize(width: 100, height: 100),
                          aspectLocked: false).save(to: defaults)
        CaptureModeMemory(mode: .area, pixelSize: nil, aspectLocked: false).save(to: defaults)
        XCTAssertNil(CaptureModeMemory.load(from: defaults).pixelSize)
    }

    func testHalfASizeIsNoSize() {
        defaults.set(800.0, forKey: "screenshot.lastWidth")
        XCTAssertNil(CaptureModeMemory.load(from: defaults).pixelSize)
    }

    func testAZeroSizeIsIgnored() {
        defaults.set(0.0, forKey: "screenshot.lastWidth")
        defaults.set(0.0, forKey: "screenshot.lastHeight")
        XCTAssertNil(CaptureModeMemory.load(from: defaults).pixelSize)
    }
}

final class CountdownTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 5_000)

    func testItShowsTheFullDurationForTheFirstSecond() {
        // Ceil, not floor: the number is how many seconds are left, so a 3-second timer must read
        // "3" immediately rather than flashing 2.
        XCTAssertEqual(Countdown.state(now: start, startedAt: start, duration: 3),
                       .counting(secondsLeft: 3))
        XCTAssertEqual(Countdown.state(now: start.addingTimeInterval(0.5),
                                       startedAt: start, duration: 3),
                       .counting(secondsLeft: 3))
    }

    func testItCountsDown() {
        XCTAssertEqual(Countdown.state(now: start.addingTimeInterval(1.2),
                                       startedAt: start, duration: 3),
                       .counting(secondsLeft: 2))
        XCTAssertEqual(Countdown.state(now: start.addingTimeInterval(2.5),
                                       startedAt: start, duration: 3),
                       .counting(secondsLeft: 1))
    }

    func testItFiresAtTheEnd() {
        XCTAssertEqual(Countdown.state(now: start.addingTimeInterval(3),
                                       startedAt: start, duration: 3), .fired)
        XCTAssertEqual(Countdown.state(now: start.addingTimeInterval(99),
                                       startedAt: start, duration: 3), .fired)
    }

    func testAClockThatJumpsBackwardsNeverShowsMoreThanTheTimerWasSetFor() {
        XCTAssertEqual(Countdown.state(now: start.addingTimeInterval(-500),
                                       startedAt: start, duration: 3),
                       .counting(secondsLeft: 3))
    }
}
