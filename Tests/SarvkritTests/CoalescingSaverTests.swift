import XCTest
@testable import Sarvkrit

/// The writer three stores now share.
final class CoalescingSaverTests: XCTestCase {

    func testABurstOfChangesProducesOneWriteOfTheLastState() {
        // The property the whole type exists for: persisting is idempotent, so only the newest
        // snapshot means anything and the older ones are pure cost.
        let lock = NSLock()
        var written: [Int] = []
        let saver = CoalescingSaver<Int>(label: "test.coalesce") { value in
            lock.lock(); written.append(value); lock.unlock()
            // Slow enough that the later schedules land while this one is in flight.
            Thread.sleep(forTimeInterval: 0.02)
        }

        for value in 1...20 { saver.schedule(value) }
        saver.flush()

        lock.lock(); let result = written; lock.unlock()
        XCTAssertEqual(result.last, 20, "the newest state must be the one on disk")
        XCTAssertLessThan(result.count, 20, "writes were not coalesced at all")
    }

    func testFlushWritesAPendingSnapshotSynchronously() {
        // Quit depends on this: the trade of writing off the main thread is only safe if
        // quitting waits, or the change the user just made is the one that gets lost.
        let lock = NSLock()
        var written: [String] = []
        let saver = CoalescingSaver<String>(label: "test.flush") { value in
            lock.lock(); written.append(value); lock.unlock()
        }
        saver.schedule("only")
        saver.flush()
        lock.lock(); let result = written; lock.unlock()
        XCTAssertEqual(result.last, "only")
    }

    func testFlushWithNothingPendingWritesNothing() {
        let lock = NSLock()
        var count = 0
        let saver = CoalescingSaver<Int>(label: "test.empty") { _ in
            lock.lock(); count += 1; lock.unlock()
        }
        saver.flush()
        saver.flush()
        lock.lock(); let result = count; lock.unlock()
        XCTAssertEqual(result, 0)
    }

    func testSchedulingAfterAFlushStillWrites() {
        // The drain loop clears `isDraining` on the way out; if flush left it set, every later
        // schedule would be silently dropped.
        let lock = NSLock()
        var written: [Int] = []
        let saver = CoalescingSaver<Int>(label: "test.reuse") { value in
            lock.lock(); written.append(value); lock.unlock()
        }
        saver.schedule(1)
        saver.flush()
        saver.schedule(2)
        saver.flush()
        lock.lock(); let result = written; lock.unlock()
        XCTAssertEqual(result.last, 2)
    }
}
