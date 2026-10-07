import AppKit
import Foundation

/// What runs one export: `StudioExporter` in the app, a stand-in in tests.
protocol ExportRunning: Sendable {
    func run(_ work: ExportJob.Work,
             onProgress: @Sendable @escaping (StudioExporter.Progress) -> Void) async throws
    func cancel() async
}

extension StudioExporter: ExportRunning {
    func run(_ work: ExportJob.Work,
             onProgress: @Sendable @escaping (Progress) -> Void) async throws {
        try await export(project: work.project, events: work.events, recording: work.bundle,
                         preset: work.preset, to: work.destination, onProgress: onProgress)
    }
}

/// One export, waiting or under way.
struct ExportJob: Identifiable, Equatable {

    /// Everything the export reads, copied when it was asked for.
    ///
    /// **A snapshot, not a reference to the editor.** All four are values, so an edit made while a
    /// job waits — or closing the window it came from — cannot change what it writes.
    struct Work: Equatable {
        var project: StudioProject
        var events: EventLog
        var bundle: RecordingBundle
        var preset: ExportPreset
        var destination: URL
    }

    enum State: Equatable {
        case queued
        case running
    }

    let id = UUID()
    let work: Work
    /// What the list calls it: the recording's name.
    let title: String
    var state: State = .queued
    var progress: Double = 0
    var startedAt: Date?

    /// Seconds left, once there is enough of a run to extrapolate from.
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard state == .running, let startedAt, progress > 0.02, progress < 1 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        return elapsed / progress * (1 - progress)
    }
}

/// Every export the app is doing, **one at a time.**
///
/// Each editor used to start its own export the moment it was asked, so two windows — or a script
/// and a window — ran two at once and each took twice as long, both looking stuck. Exports now go
/// through here: the first runs, the rest wait their turn, and any of them can be cancelled.
@MainActor
final class ExportQueue: ObservableObject {

    static let shared = ExportQueue()

    enum Outcome: Equatable {
        case finished
        case failed
        case cancelled
    }

    /// Waiting and running jobs, in the order they will run. A job leaves when it ends.
    @Published private(set) var jobs: [ExportJob] = []

    private let makeRunner: () -> any ExportRunning
    private let report: @MainActor (ExportJob, Outcome, _ queueIsEmpty: Bool) -> Void
    private var runner: (any ExportRunning)?
    /// Called once the queue is empty, by a quit that is waiting for it.
    private var whenDrained: [() -> Void] = []

    init(makeRunner: @escaping () -> any ExportRunning = { StudioExporter() },
         report: @escaping @MainActor (ExportJob, Outcome, Bool) -> Void = ExportQueue.announce) {
        self.makeRunner = makeRunner
        self.report = report
    }

    var isBusy: Bool { !jobs.isEmpty }
    var running: ExportJob? { jobs.first { $0.state == .running } }

    /// Adds an export to the end of the line. Nil when that file is being written right now.
    ///
    /// **One writer per file.** Asking again for a file that is still waiting replaces the waiting
    /// request — the newer settings are the ones wanted — but a file mid-write cannot be taken
    /// over, so that request is refused rather than queued to clobber it.
    @discardableResult
    func enqueue(_ work: ExportJob.Work, title: String) -> ExportJob? {
        let target = work.destination.standardizedFileURL
        if let clash = jobs.first(where: { $0.work.destination.standardizedFileURL == target }) {
            guard clash.state == .queued else { return nil }
            jobs.removeAll { $0.id == clash.id }
            report(clash, .cancelled, false)
        }
        let job = ExportJob(work: work, title: title)
        jobs.append(job)
        startNextIfIdle()
        return jobs.first { $0.id == job.id }
    }

    /// Stops one export: a waiting one is dropped, a running one is told to stop and the next
    /// starts when it has.
    func cancel(_ id: ExportJob.ID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.state {
        case .queued:
            jobs.removeAll { $0.id == id }
            report(job, .cancelled, jobs.isEmpty)
            drainIfEmpty()
        case .running:
            if let runner { Task { await runner.cancel() } }
        }
    }

    func cancelAll() {
        let waiting = jobs.filter { $0.state == .queued }
        jobs.removeAll { $0.state == .queued }
        for job in waiting { report(job, .cancelled, false) }
        if let running { cancel(running.id) }
        drainIfEmpty()
    }

    /// Where a waiting job stands: 1 is next.
    func place(of id: ExportJob.ID) -> Int? {
        let waiting = jobs.filter { $0.state == .queued }
        return waiting.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// Cancels everything and calls `done` once nothing is running, or after `timeout` — so a quit
    /// is never held hostage by an export that will not stop.
    func stopAll(timeout: TimeInterval = 3, then done: @escaping () -> Void) {
        var called = false
        let once = {
            guard !called else { return }
            called = true
            done()
        }
        whenDrained.append(once)
        cancelAll()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            once()
        }
    }

    // MARK: - Running

    /// **Synchronous on purpose.** The job is marked running and its exporter exists before
    /// `enqueue` returns, so a Cancel pressed immediately afterwards has something to cancel —
    /// and `StudioExporter` honours a cancel that arrives before it has even started.
    private func startNextIfIdle() {
        guard runner == nil, let index = jobs.firstIndex(where: { $0.state == .queued }) else {
            return
        }
        let runner = makeRunner()
        self.runner = runner
        jobs[index].state = .running
        jobs[index].startedAt = Date()
        let job = jobs[index]

        Task { @MainActor [weak self] in
            let outcome: Outcome
            do {
                try await runner.run(job.work, onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in self?.update(job.id, to: progress.fraction) }
                })
                outcome = .finished
            } catch StudioExporter.ExportError.cancelled {
                outcome = .cancelled
            } catch {
                outcome = .failed
            }
            self?.finish(job.id, outcome)
        }
    }

    /// **Forward only, and only while running.** Each progress report hops to the main actor on
    /// its own, so they can arrive out of order — and one can arrive after the job has ended,
    /// which must not bring it back. Coarsened to a fifth of a percent: a title bar redrawn for
    /// every frame of a long export is work for nothing.
    private func update(_ id: ExportJob.ID, to fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .running,
              fraction >= jobs[index].progress + 0.002 || fraction >= 1 else { return }
        jobs[index].progress = min(1, fraction)
    }

    private func finish(_ id: ExportJob.ID, _ outcome: Outcome) {
        runner = nil
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        report(job, outcome, jobs.isEmpty)
        startNextIfIdle()
        drainIfEmpty()
    }

    private func drainIfEmpty() {
        guard jobs.isEmpty, !whenDrained.isEmpty else { return }
        let waiting = whenDrained
        whenDrained = []
        waiting.forEach { $0() }
    }

    // MARK: - Saying so

    /// A toast per export, and the Finder once at the end.
    ///
    /// **Revealed once, not per file.** Each finished export used to bring the Finder forward; with
    /// three queued that is focus stolen three times while somebody is trying to work.
    static func announce(_ job: ExportJob, _ outcome: Outcome, queueIsEmpty: Bool) {
        switch outcome {
        case .finished:
            ToastPresenter.shared.show("Exported \(job.work.destination.lastPathComponent)",
                                       symbolName: "square.and.arrow.up")
            if queueIsEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([job.work.destination])
            }
        case .failed:
            ToastPresenter.shared.show("Export failed — \(job.work.destination.lastPathComponent)",
                                       symbolName: "exclamationmark.triangle")
        case .cancelled:
            break
        }
    }
}
