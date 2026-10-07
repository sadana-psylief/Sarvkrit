import XCTest
@testable import Sarvkrit

/// The SMC path against the real hardware this suite is running on.
///
/// **No test in this file ever writes an SMC key.** Reading is unprivileged and harmless; writing
/// hands a fan to us and needs root, and a test suite is the last place that should happen.
///
/// Every assertion skips rather than fails when the hardware cannot answer, on the same reasoning
/// as `SystemMonitorIOKitSmokeTests`: a desktop with no fans and a Mac whose SMC has moved are
/// facts about the machine, not regressions in this code.
final class FanSMCSmokeTests: XCTestCase {

    private func openClient() throws -> SMCClient {
        let client = SMCClient()
        guard client.open() else { throw XCTSkip("no AppleSMC user client on this Mac") }
        return client
    }

    func testTheFanCountReadsAsASmallNumber() throws {
        let client = try openClient()
        defer { client.close() }
        guard let count = client.readDouble(FanKey.count) else {
            throw XCTSkip("this Mac does not publish FNum")
        }
        XCTAssertTrue((0...16).contains(count), "implausible fan count: \(count)")
    }

    func testEachFanReportsARangeItsSpeedFallsInside() throws {
        let client = try openClient()
        defer { client.close() }
        guard let count = client.readDouble(FanKey.count).map({ Int($0) }), count > 0 else {
            throw XCTSkip("fanless Mac")
        }
        for index in 0..<min(count, 10) {
            guard let key = FanKey.minimum(index), let minimum = client.readDouble(key),
                  let maxKey = FanKey.maximum(index), let maximum = client.readDouble(maxKey)
            else { continue }

            XCTAssertGreaterThan(maximum, minimum, "fan \(index) has no headroom")
            XCTAssertLessThan(maximum, 12000, "fan \(index) maximum is implausible")

            guard let acKey = FanKey.actual(index), let rpm = client.readDouble(acKey) else { continue }
            // Zero is legitimate — Apple Silicon stops its fans when cool — so the floor is 0
            // rather than the fan's minimum. The ceiling has slack for a fan on its way down.
            XCTAssertTrue((0...(maximum * 1.1)).contains(rpm), "fan \(index) reports \(rpm) rpm")
        }
    }

    /// The type codes are the assumption the codec is built on. If a macOS release changes one,
    /// `SMCValueCodec` starts returning nil and every fan reading silently becomes a dash — so
    /// the codes are asserted here rather than discovered in the field.
    func testTheFanKeysUseTypesTheCodecUnderstands() throws {
        let client = try openClient()
        defer { client.close() }
        guard let count = client.readDouble(FanKey.count).map({ Int($0) }), count > 0 else {
            throw XCTSkip("fanless Mac")
        }
        for key in [FanKey.actual(0), FanKey.minimum(0), FanKey.maximum(0), FanKey.target(0)] {
            guard let key, let info = client.keyInfo(key) else { continue }
            XCTAssertNotNil(
                SMCValueCodec.decode(type: info.type, bytes: [UInt8](repeating: 0, count: info.size)),
                "\(key) has type \(SMCKey(code: info.type)) which the codec does not decode")
        }
    }

    /// The leak test. A missing IOServiceClose is invisible in one call and terminal over a day
    /// at one sample every two seconds. Mirrors the 500-iteration loop in the monitor's suite.
    func testRepeatedFanPollingIsStableAndReleasesEverything() throws {
        let sampler = FanSampler()
        guard sampler.read() != .unreadable else { throw XCTSkip("no readable SMC on this Mac") }
        for iteration in 0..<500 {
            XCTAssertNotEqual(sampler.read(), .unreadable, "fan read failed on iteration \(iteration)")
        }
    }
}
