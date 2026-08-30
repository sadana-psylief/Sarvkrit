import XCTest
@testable import Sarvkrit

/// FSEvents against a real directory. Slower than the pure tests, but this is the one piece of the
/// Files engine whose behaviour can't be reasoned about from the types alone.
final class FolderWatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testANewFileIsReported() throws {
        let reported = expectation(description: "watcher reported a change")
        var seen: [URL] = []

        let watcher = FolderWatcher(coalesceInterval: 0.2) { urls in
            seen = urls
            reported.fulfill()
        }
        XCTAssertTrue(watcher.start(watching: [root]))
        defer { watcher.stop() }

        // FSEvents starts from "now", so the write has to happen after the stream is running.
        try "hello".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        wait(for: [reported], timeout: 10)
        XCTAssertTrue(
            seen.contains { $0.lastPathComponent == "new.txt" },
            "expected new.txt in \(seen.map(\.lastPathComponent))"
        )
    }

    func testABurstOfWritesIsCoalescedIntoFewCallbacks() throws {
        // Asserting *exactly one* callback would be flaky: FSEvents can legitimately split a burst
        // across the coalescing window. The property that matters is that eight writes don't cause
        // eight rule evaluations.
        let fileCount = 8
        let lock = NSLock()
        var callbacks = 0
        var seen = Set<String>()

        let watcher = FolderWatcher(coalesceInterval: 0.4) { urls in
            lock.lock()
            callbacks += 1
            urls.forEach { seen.insert($0.lastPathComponent) }
            lock.unlock()
        }
        XCTAssertTrue(watcher.start(watching: [root]))
        defer { watcher.stop() }

        for index in 0..<fileCount {
            try "x".write(to: root.appendingPathComponent("f\(index).txt"), atomically: true, encoding: .utf8)
        }

        let settled = expectation(description: "burst settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { settled.fulfill() }
        wait(for: [settled], timeout: 10)

        lock.lock()
        let (finalCallbacks, finalSeen) = (callbacks, seen)
        lock.unlock()

        XCTAssertGreaterThan(finalSeen.count, 1, "the watcher should have reported the burst")
        XCTAssertLessThan(finalCallbacks, fileCount, "coalescing isn't happening: \(finalCallbacks) callbacks")
    }

    func testStoppingSilencesTheWatcher() throws {
        let unexpected = expectation(description: "must not fire after stop")
        unexpected.isInverted = true

        let watcher = FolderWatcher(coalesceInterval: 0.2) { _ in unexpected.fulfill() }
        XCTAssertTrue(watcher.start(watching: [root]))
        watcher.stop()

        try "x".write(to: root.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
        wait(for: [unexpected], timeout: 2)
    }

    func testWatchingNothingSucceedsWithoutAStream() {
        // Every rule disabled is the normal state on a fresh install; it must not be an error.
        let watcher = FolderWatcher { _ in XCTFail("should never fire") }
        XCTAssertTrue(watcher.start(watching: []))
        watcher.stop()
    }
}
