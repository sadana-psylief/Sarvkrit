import Foundation
import XCTest
@testable import Sarvkrit

/// The export queue: one export at a time, any of them cancellable.
///
/// **Against a stand-in exporter that finishes when told to**, so "the second waits for the first"
/// is a fact the test controls rather than a race it hopes to win. The real exporter is driven
/// through the queue once, in `StudioExportTests`.
@MainActor
final class ExportQueueTests: XCTestCase {

    private var ledger: Ledger!
    private var outcomes: [String: ExportQueue.Outcome] = [:]
    private var queue: ExportQueue!

    override func setUp() async throws {
        ledger = Ledger()
        outcomes = [:]
        let ledger = ledger!
        queue = ExportQueue(
            makeRunner: { StubRunner(ledger: ledger) },
            report: { [weak self] job, outcome, _ in self?.outcomes[job.title] = outcome })
    }

    // MARK: - In turn

    func testJobsRunOneAtATime() async throws {
        let first = try XCTUnwrap(queue.enqueue(work("a"), title: "a"))
        let second = try XCTUnwrap(queue.enqueue(work("b"), title: "b"))
        XCTAssertEqual(first.state, .running)
        XCTAssertEqual(queue.place(of: second.id), 1)

        try await waitUntil { self.ledger.started == ["a"] }
        ledger.end("a")
        try await waitUntil { self.ledger.started == ["a", "b"] }
        ledger.end("b")
        try await waitUntil { self.queue.jobs.isEmpty }

        XCTAssertEqual(ledger.mostAtOnce, 1, "two exports ran at the same time")
        XCTAssertEqual(outcomes, ["a": .finished, "b": .finished])
    }

    func testAFailureDoesNotStallTheQueue() async throws {
        queue.enqueue(work("a"), title: "a")
        queue.enqueue(work("b"), title: "b")
        try await waitUntil { self.ledger.started == ["a"] }

        ledger.end("a", throwing: StudioExporter.ExportError.cannotWrite)
        try await waitUntil { self.ledger.started == ["a", "b"] }

        XCTAssertEqual(outcomes["a"], .failed)
    }

    func testProgressIsReported() async throws {
        let job = try XCTUnwrap(queue.enqueue(work("a"), title: "a"))
        try await waitUntil { self.queue.jobs.first?.progress == 0.5 }
        XCTAssertEqual(queue.jobs.first?.id, job.id)
    }

    // MARK: - Cancelling

    func testCancellingAWaitingJobLeavesTheRunningOneAlone() async throws {
        queue.enqueue(work("a"), title: "a")
        let second = try XCTUnwrap(queue.enqueue(work("b"), title: "b"))
        let third = try XCTUnwrap(queue.enqueue(work("c"), title: "c"))
        try await waitUntil { self.ledger.started == ["a"] }

        queue.cancel(second.id)

        XCTAssertEqual(queue.jobs.map(\.title), ["a", "c"])
        XCTAssertEqual(queue.running?.title, "a")
        XCTAssertEqual(queue.place(of: third.id), 1)
        XCTAssertEqual(outcomes["b"], .cancelled)

        ledger.end("a")
        try await waitUntil { self.ledger.started == ["a", "c"] }
    }

    func testCancellingTheRunningJobStartsTheNext() async throws {
        let first = try XCTUnwrap(queue.enqueue(work("a"), title: "a"))
        queue.enqueue(work("b"), title: "b")
        try await waitUntil { self.ledger.started == ["a"] }

        queue.cancel(first.id)

        try await waitUntil { self.ledger.started == ["a", "b"] }
        XCTAssertEqual(outcomes["a"], .cancelled)
        XCTAssertEqual(ledger.mostAtOnce, 1)
    }

    /// **The Cancel pressed straight after Export.** The job must already be running, with an
    /// exporter to tell, by the time `enqueue` returns.
    func testCancellingImmediatelyAfterEnqueueingStopsIt() async throws {
        let job = try XCTUnwrap(queue.enqueue(work("a"), title: "a"))
        queue.cancel(job.id)

        try await waitUntil { self.queue.jobs.isEmpty }
        XCTAssertEqual(outcomes["a"], .cancelled)
    }

    func testCancelAllEmptiesTheQueue() async throws {
        queue.enqueue(work("a"), title: "a")
        queue.enqueue(work("b"), title: "b")
        queue.enqueue(work("c"), title: "c")
        try await waitUntil { self.ledger.started == ["a"] }

        queue.cancelAll()

        try await waitUntil { self.queue.jobs.isEmpty }
        XCTAssertEqual(outcomes, ["a": .cancelled, "b": .cancelled, "c": .cancelled])
        XCTAssertEqual(ledger.started, ["a"], "a cancelled job was started anyway")
    }

    /// What a quit waits for: called once nothing is left, and only once.
    func testStopAllCallsBackOnceEverythingHasStopped() async throws {
        queue.enqueue(work("a"), title: "a")
        queue.enqueue(work("b"), title: "b")
        try await waitUntil { self.ledger.started == ["a"] }

        var calls = 0
        queue.stopAll(timeout: 0.2) { calls += 1 }

        try await waitUntil { calls == 1 }
        XCTAssertTrue(queue.jobs.isEmpty)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(calls, 1, "the timeout called back a second time")
    }

    func testStopAllWithNothingRunningCallsBackAtOnce() {
        var calls = 0
        queue.stopAll { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    // MARK: - One writer per file

    func testAFileBeingWrittenCannotBeQueuedAgain() async throws {
        queue.enqueue(work("a"), title: "a")
        try await waitUntil { self.ledger.started == ["a"] }

        XCTAssertNil(queue.enqueue(work("a"), title: "a again"))
        XCTAssertEqual(queue.jobs.count, 1)
    }

    func testAskingAgainForAWaitingFileReplacesIt() async throws {
        queue.enqueue(work("a"), title: "a")
        queue.enqueue(work("b", preset: .web), title: "b")
        let newer = try XCTUnwrap(queue.enqueue(work("b", preset: .small), title: "b, smaller"))

        XCTAssertEqual(queue.jobs.map(\.title), ["a", "b, smaller"])
        XCTAssertEqual(queue.jobs.last?.id, newer.id)
        XCTAssertEqual(outcomes["b"], .cancelled)
    }

    // MARK: - What the title bar says

    func testTheTimeLeftIsLeftOffUntilThereIsEnoughToGoBy() {
        var job = ExportJob(work: work("a"), title: "a")
        job.state = .running
        job.startedAt = Date(timeIntervalSinceNow: -60)
        job.progress = 0.01
        XCTAssertNil(job.remaining())
        job.progress = 0.25
        XCTAssertEqual(try XCTUnwrap(job.remaining()), 180, accuracy: 1)
    }

    func testDescriptions() {
        XCTAssertEqual(ExportStatusView.describe(progress: 0.42, remaining: nil), "42%")
        XCTAssertEqual(ExportStatusView.describe(progress: 0.42, remaining: 200),
                       "42% · about 3 min left")
        XCTAssertEqual(ExportStatusView.describe(remaining: 30), "under a minute left")
        XCTAssertEqual(ExportStatusView.describe(place: 1), "Queued — next")
        XCTAssertEqual(ExportStatusView.describe(place: 3), "Queued — 3rd in line")
    }

    // MARK: - Helpers

    private func work(_ name: String, preset: ExportPreset = .web) -> ExportJob.Work {
        ExportJob.Work(
            project: StudioProject(canvasSize: CGSize(width: 160, height: 120),
                                   timeline: Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 1)])),
            events: EventLog(),
            bundle: RecordingBundle(root: URL(fileURLWithPath: "/tmp/\(name).sarvrec")),
            preset: preset,
            destination: URL(fileURLWithPath: "/tmp/\(name).mp4"))
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// What the stand-in exporters did, and the lever that finishes each one.
@MainActor
private final class Ledger {
    /// Names, in the order they started.
    private(set) var started: [String] = []
    private(set) var mostAtOnce = 0
    private var running = 0
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    /// A cancel that arrived before its export had got as far as waiting.
    private var cancelledBeforeWaiting: Set<String> = []

    func begin(_ name: String, _ continuation: CheckedContinuation<Void, Error>) {
        started.append(name)
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        if cancelledBeforeWaiting.remove(name) != nil {
            running -= 1
            continuation.resume(throwing: StudioExporter.ExportError.cancelled)
            return
        }
        pending[name] = continuation
    }

    func end(_ name: String, throwing error: Error? = nil) {
        guard let continuation = pending.removeValue(forKey: name) else { return }
        running -= 1
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func cancel(_ name: String) {
        if pending[name] != nil {
            end(name, throwing: StudioExporter.ExportError.cancelled)
        } else {
            cancelledBeforeWaiting.insert(name)
        }
    }
}

/// Stands in for `StudioExporter`: reports halfway, then waits for the ledger to finish it —
/// honouring a cancel that arrives before it has started, as the real one does.
private actor StubRunner: ExportRunning {
    private let ledger: Ledger
    private var name: String?
    private var cancelledEarly = false

    init(ledger: Ledger) { self.ledger = ledger }

    func run(_ work: ExportJob.Work,
             onProgress: @Sendable @escaping (StudioExporter.Progress) -> Void) async throws {
        if cancelledEarly { throw StudioExporter.ExportError.cancelled }
        let name = work.destination.deletingPathExtension().lastPathComponent
        self.name = name
        onProgress(StudioExporter.Progress(completed: 1, total: 2))
        let ledger = self.ledger
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in ledger.begin(name, continuation) }
        }
    }

    func cancel() async {
        guard let name else {
            cancelledEarly = true
            return
        }
        await ledger.cancel(name)
    }
}
