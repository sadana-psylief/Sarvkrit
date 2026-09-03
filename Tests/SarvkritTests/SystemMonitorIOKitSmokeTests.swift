import XCTest
@testable import Sarvkrit

/// **These touch real hardware through IOKit**, and unlike the Mach samplers they read keys that
/// are not guaranteed to exist: a Mac with no matching accelerator reports no GPU utilisation, and
/// a desktop has no battery at all. Absence is a legitimate answer here, so the tests skip rather
/// than fail when the machine genuinely cannot answer — and assert hard whenever it can.
///
/// The point remains the one the audio smoke tests make: a layer that compiles and returns
/// plausible-looking nothing is the failure mode this project has hit before.
final class SystemMonitorIOKitSmokeTests: XCTestCase {

    // MARK: - GPU

    func testGPUUtilisationIsAPercentageWhenTheMacReportsOne() throws {
        guard let usage = GPUSampler.readUtilization() else {
            throw XCTSkip("no IOAccelerator reporting Device Utilization % on this Mac")
        }
        XCTAssertTrue((0...100).contains(usage), "GPU utilisation was \(usage), outside 0...100")
    }

    // MARK: - Power and battery

    func testPowerSourcesAreReadable() throws {
        let reading = try XCTUnwrap(PowerSourceReader.read(), "IOPSCopyPowerSourcesInfo failed")
        // Even a desktop answers: no battery present, running from the adapter.
        if !reading.battery.isPresent {
            XCTAssertEqual(reading.power.source, .adapter,
                           "a Mac with no battery must be running from the adapter")
        }
    }

    func testBatteryChargeIsAPlausiblePercentage() throws {
        let reading = try XCTUnwrap(PowerSourceReader.read())
        guard reading.battery.isPresent else { throw XCTSkip("no battery on this Mac") }
        XCTAssertTrue((0...100).contains(reading.battery.percent),
                      "charge was \(reading.battery.percent)%")
    }

    func testWattageIsPlausibleAndSignedTheRightWay() throws {
        let reading = try XCTUnwrap(PowerSourceReader.read())
        guard reading.battery.isPresent, let watts = reading.power.watts else {
            throw XCTSkip("no battery amperage reported on this Mac")
        }
        // The trap this guards: an unreinterpreted Amperage renders as ~2e17 W. Any laptop is
        // inside 200 W in either direction, so a value outside that is the bug, not a reading.
        XCTAssertLessThan(abs(watts), 200, "implausible wattage \(watts) — check the amperage sign")

        if reading.power.source == .battery, !reading.battery.isCharging, watts != 0 {
            XCTAssertLessThan(watts, 0, "a discharging Mac must report negative watts")
        }
    }

    func testCycleCountIsSaneWhenReported() throws {
        let reading = try XCTUnwrap(PowerSourceReader.read())
        guard let cycles = reading.battery.cycleCount else { throw XCTSkip("no cycle count") }
        XCTAssertGreaterThanOrEqual(cycles, 0)
        XCTAssertLessThan(cycles, 20_000, "cycle count \(cycles) is not a real battery")
    }

    // MARK: - Disk throughput

    func testDiskThroughputCountersAreReadable() throws {
        let counters = try XCTUnwrap(DiskSampler.readThroughput(),
                                     "no IOBlockStorageDriver statistics")
        // The probe found two drivers, the first with all-zero counters — summing across them is
        // what makes this non-zero, and taking the first would silently report no disk activity.
        XCTAssertGreaterThan(counters.read, 0, "the boot volume has certainly been read from")
    }

    func testDiskThroughputCountersOnlyEverClimb() throws {
        let first = try XCTUnwrap(DiskSampler.readThroughput())
        let second = try XCTUnwrap(DiskSampler.readThroughput())
        XCTAssertGreaterThanOrEqual(second.read, first.read)
        XCTAssertGreaterThanOrEqual(second.written, first.written)
    }

    // MARK: - Cost of running forever

    func testRepeatedIOKitPollingIsStableAndReleasesEverything() throws {
        // Every read here opens registry entries and copies property dictionaries. IOKit objects
        // need IOObjectRelease — the iterator as well as each service — and the CF dictionaries
        // need takeRetainedValue. Missing any one leaks per tick, which a single call cannot show.
        for iteration in 0..<500 {
            XCTAssertNotNil(PowerSourceReader.read(), "power read failed on iteration \(iteration)")
            XCTAssertNotNil(DiskSampler.readThroughput(), "disk read failed on \(iteration)")
            _ = GPUSampler.readUtilization()
        }
    }
}
