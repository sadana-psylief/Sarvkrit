import XCTest
@testable import Sarvkrit

/// When to warn that the camera or microphone came on, and when to keep quiet.
///
/// Video apps toggle the camera constantly — on every layout change, every screen share. Without
/// coalescing this feature would produce a stream of warnings, and a warning shown twenty times is
/// one nobody reads the twenty-first.
final class DeviceActivityLogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

    // MARK: - Announcing

    func testTurningOnAnnouncesOnce() {
        var log = DeviceActivityLog()
        XCTAssertEqual(log.record(.camera, isOn: true, at: start), .turnedOn(.camera))
    }

    func testStayingOnAnnouncesNothingFurther() {
        // The poll fires every half second; only the transition is news.
        var log = DeviceActivityLog()
        _ = log.record(.camera, isOn: true, at: start)
        for tick in 1...20 {
            XCTAssertEqual(log.record(.camera, isOn: true, at: at(Double(tick) * 0.5)), .none)
        }
    }

    func testTurningOffAnnouncesNothing() {
        // Only coming on is worth interrupting someone for.
        var log = DeviceActivityLog()
        _ = log.record(.camera, isOn: true, at: start)
        XCTAssertEqual(log.record(.camera, isOn: false, at: at(5)), .none)
    }

    // MARK: - Coalescing, the point of this type

    func testAFlickerWithinTheWindowIsNotAnnouncedAgain() {
        var log = DeviceActivityLog()
        _ = log.record(.camera, isOn: true, at: start)
        _ = log.record(.camera, isOn: false, at: at(1))
        XCTAssertEqual(log.record(.camera, isOn: true, at: at(2)), .none,
                       "the same use flickering is not a new use")
    }

    func testAFlickerDoesNotPileUpEntries() {
        var log = DeviceActivityLog()
        for tick in 0..<10 {
            _ = log.record(.camera, isOn: true, at: at(Double(tick) * 2))
            _ = log.record(.camera, isOn: false, at: at(Double(tick) * 2 + 1))
        }
        XCTAssertEqual(log.entries.count, 1, "ten flickers, one session")
    }

    func testAGenuinelyNewSessionIsAnnounced() {
        var log = DeviceActivityLog()
        _ = log.record(.camera, isOn: true, at: start)
        _ = log.record(.camera, isOn: false, at: at(1))
        let later = at(DeviceActivityLog.coalescingWindow + 5)
        XCTAssertEqual(log.record(.camera, isOn: true, at: later), .turnedOn(.camera))
        XCTAssertEqual(log.entries.count, 2)
    }

    func testTheWindowIsLongEnoughToBeUseful() {
        // Guards the tuning. Too short and a video call produces a stream of warnings.
        XCTAssertGreaterThanOrEqual(DeviceActivityLog.coalescingWindow, 10)
    }

    // MARK: - The two devices are independent

    func testCameraAndMicrophoneDoNotCoalesceWithEachOther() {
        var log = DeviceActivityLog()
        XCTAssertEqual(log.record(.camera, isOn: true, at: start), .turnedOn(.camera))
        XCTAssertEqual(log.record(.microphone, isOn: true, at: at(1)), .turnedOn(.microphone))
    }

    func testEachDeviceReportsItsOwnState() {
        var log = DeviceActivityLog()
        _ = log.record(.camera, isOn: true, at: start)
        XCTAssertTrue(log.isCameraOn)
        XCTAssertFalse(log.isMicrophoneInUse)

        _ = log.record(.camera, isOn: false, at: at(1))
        XCTAssertFalse(log.isCameraOn)
    }

    // MARK: - The log itself

    func testNewestSessionsComeFirst() {
        var log = DeviceActivityLog()
        _ = log.record(.camera, isOn: true, at: start)
        _ = log.record(.camera, isOn: false, at: at(1))
        let later = at(DeviceActivityLog.coalescingWindow + 5)
        _ = log.record(.camera, isOn: true, at: later)
        XCTAssertEqual(log.entries.first?.startedAt, later)
    }

    func testTheLogIsCapped() {
        // Recent history, not an audit trail — and an unbounded list in a menu bar app is a leak.
        var log = DeviceActivityLog()
        let gap = DeviceActivityLog.coalescingWindow + 5
        for session in 0..<(DeviceActivityLog.limit + 10) {
            let base = Double(session) * gap * 2
            _ = log.record(.camera, isOn: true, at: at(base))
            _ = log.record(.camera, isOn: false, at: at(base + 1))
        }
        XCTAssertEqual(log.entries.count, DeviceActivityLog.limit)
    }

    func testAnOffWithNoMatchingOnIsHarmless() {
        // The first poll after launch can easily see a device already off.
        var log = DeviceActivityLog()
        XCTAssertEqual(log.record(.camera, isOn: false, at: start), .none)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testClearingEmptiesIt() {
        var log = DeviceActivityLog()
        _ = log.record(.camera, isOn: true, at: start)
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertFalse(log.isCameraOn)
    }
}
