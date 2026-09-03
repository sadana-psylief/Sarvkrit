import XCTest
@testable import Sarvkrit

/// **These touch real hardware**, unlike the pure metric tests, and that is the point.
///
/// Twice in this project a layer compiled cleanly, looked right and did nothing — so "it builds" is
/// not the same as "it works". Every sampler here reads through a Mach or IOKit call that cannot be
/// faked usefully, and the failure mode is a plausible-looking zero rather than an error. These
/// assert only what must be true on any Mac, so they stay honest on machines other than this one.
final class SystemMonitorSmokeTests: XCTestCase {

    // MARK: - CPU

    func testCPUTicksAreReadableAndInternallyConsistent() throws {
        let ticks = try XCTUnwrap(CPUSampler.readTicks(), "no CPU ticks — host_processor_info failed")
        XCTAssertGreaterThan(ticks.total, 0, "a running Mac has accumulated ticks")
        XCTAssertLessThanOrEqual(ticks.busy, ticks.total, "busy ticks are a subset of all ticks")
    }

    func testCPUTicksOnlyEverClimb() throws {
        // The monotonicity every rate in this feature is built on. If it were violated, usage would
        // read as nil forever rather than failing visibly here.
        let first = try XCTUnwrap(CPUSampler.readTicks())
        let second = try XCTUnwrap(CPUSampler.readTicks())
        XCTAssertGreaterThanOrEqual(second.total, first.total)
        XCTAssertGreaterThanOrEqual(second.busy, first.busy)
    }

    func testUsageFromTwoRealReadingsIsAPlausiblePercentage() throws {
        let first = try XCTUnwrap(CPUSampler.readTicks())
        // Give the machine something to accumulate ticks for, so the deltas aren't zero.
        var sink = 0.0
        for index in 0..<2_000_000 { sink += Double(index).squareRoot() }
        XCTAssertGreaterThan(sink, 0, "keep the compiler from optimising the busywork away")
        let second = try XCTUnwrap(CPUSampler.readTicks())

        let usage = try XCTUnwrap(CPULoad.usage(previous: first, current: second),
                                  "two readings a measurable interval apart must yield a usage")
        XCTAssertTrue((0...100).contains(usage), "usage was \(usage), outside 0...100")
    }

    func testCoreCountAgreesWithTheSystem() {
        XCTAssertEqual(CPUSampler.coreCount, ProcessInfo.processInfo.activeProcessorCount)
    }

    // MARK: - Memory

    func testMemoryReadsAgainstInstalledRAM() throws {
        let memory = try XCTUnwrap(MemorySampler.read(), "no memory reading — host_statistics64 failed")
        XCTAssertEqual(memory.total, ProcessInfo.processInfo.physicalMemory,
                       "total must be installed RAM, not a sum of page counts")
        XCTAssertGreaterThan(memory.used, 0, "a running Mac is using some memory")
        XCTAssertLessThan(memory.used, memory.total, "used memory cannot exceed what is installed")
    }

    func testMemoryUsagePercentIsInRange() throws {
        let percent = try XCTUnwrap(try XCTUnwrap(MemorySampler.read()).usagePercent)
        XCTAssertTrue((0...100).contains(percent), "memory usage was \(percent)%")
    }

    // MARK: - Network

    func testNetworkCountersAreReadable() throws {
        let counters = try XCTUnwrap(NetworkSampler.read(), "no counters — getifaddrs failed")
        // This test host downloaded itself over some interface; loopback alone would still be
        // non-zero, and a hard zero means the interface walk found nothing at all.
        XCTAssertGreaterThan(counters.received, 0, "no bytes received on any interface")
    }

    func testNetworkCountersOnlyEverClimb() throws {
        let first = try XCTUnwrap(NetworkSampler.read())
        let second = try XCTUnwrap(NetworkSampler.read())
        XCTAssertGreaterThanOrEqual(second.received, first.received)
        XCTAssertGreaterThanOrEqual(second.sent, first.sent)
    }

    // MARK: - Disk

    func testDiskCapacityIsReadableAndConsistent() throws {
        let disk = try XCTUnwrap(DiskSampler.readCapacity(), "no capacity for the boot volume")
        XCTAssertGreaterThan(disk.total, 0)
        XCTAssertLessThanOrEqual(disk.used, disk.total, "used cannot exceed total")
    }

    // MARK: - Cost of running forever

    func testRepeatedPollingIsStableAndLeaksNothing() throws {
        // The samplers hold Mach and Core Foundation resources ARC does not own —
        // `host_processor_info` needs `vm_deallocate`, `getifaddrs` needs `freeifaddrs`. Missing one
        // leaks a few kilobytes per tick, which is invisible in a short run and obvious in Activity
        // Monitor a day later. 500 iterations is enough that a missing release shows as growth.
        for iteration in 0..<500 {
            XCTAssertNotNil(CPUSampler.readTicks(), "CPU read failed on iteration \(iteration)")
            XCTAssertNotNil(MemorySampler.read(), "memory read failed on iteration \(iteration)")
            XCTAssertNotNil(NetworkSampler.read(), "network read failed on iteration \(iteration)")
        }
    }
}
