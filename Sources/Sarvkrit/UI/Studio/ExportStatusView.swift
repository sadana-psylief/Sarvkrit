import SwiftUI

/// The export queue as one editor sees it, in its title bar.
///
/// **This editor's job first.** A running export shows its bar, its time remaining and a Cancel; a
/// waiting one says where it is in line. An editor with nothing of its own queued still says what
/// is running, so a new export that waits is never a mystery — and the list button finds every job,
/// including one started from a window that has since been closed.
struct ExportStatusView: View {
    @ObservedObject var queue: ExportQueue
    let bundle: RecordingBundle
    @State private var isShowingList = false

    private var mine: ExportJob? {
        let own = queue.jobs.filter { $0.work.bundle.root == bundle.root }
        return own.first { $0.state == .running } ?? own.first
    }

    var body: some View {
        if queue.isBusy {
            HStack(spacing: Theme.Space.sm) {
                if let job = mine {
                    status(of: job)
                } else if let running = queue.running {
                    Text("Exporting \(running.title)")
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Button { isShowingList.toggle() } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.plain).clickableCursor()
                .help("Every export, in the order they run")
                .accessibilityLabel("Show the export queue")
                .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
                    ExportQueueList(queue: queue)
                }
            }
        }
    }

    @ViewBuilder
    private func status(of job: ExportJob) -> some View {
        switch job.state {
        case .running:
            ProgressView(value: job.progress)
                .frame(width: 120)
            Text(Self.describe(progress: job.progress, remaining: job.remaining()))
                .font(.system(size: Theme.Typography.caption))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .queued:
            Text(Self.describe(place: queue.place(of: job.id)))
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
        }
        // A progress bar with no way to stop it is a hostage situation, and an export of a long
        // recording is exactly when somebody realises they picked the wrong preset.
        Button("Cancel") { queue.cancel(job.id) }
            .accessibilityLabel("Cancel the export")
    }

    /// `42% · about 3 min left`. The time is left off until there is enough of a run to judge by.
    static func describe(progress: Double, remaining: TimeInterval?) -> String {
        let percent = "\(Int(progress * 100))%"
        guard let remaining else { return percent }
        return "\(percent) · \(describe(remaining: remaining))"
    }

    static func describe(remaining seconds: TimeInterval) -> String {
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        return "about \(minutes) min left"
    }

    static func describe(place: Int?) -> String {
        guard let place, place > 1 else { return "Queued — next" }
        let ordinal = NumberFormatter()
        ordinal.numberStyle = .ordinal
        return "Queued — \(ordinal.string(from: NSNumber(value: place)) ?? "\(place)") in line"
    }
}

/// Every job, with a Cancel each and one for all of them.
struct ExportQueueList: View {
    @ObservedObject var queue: ExportQueue

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Exports")
                .font(.system(size: Theme.Typography.title, weight: .semibold))
            if queue.jobs.isEmpty {
                Text("Nothing is exporting.")
                    .font(.system(size: Theme.Typography.body))
                    .foregroundStyle(.secondary)
            }
            ForEach(queue.jobs) { job in
                HStack(spacing: Theme.Space.md) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.title).font(.system(size: Theme.Typography.body))
                        Text("\(job.work.preset.name) · \(job.work.destination.lastPathComponent)")
                            .font(.system(size: Theme.Typography.caption))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(job.state == .running
                         ? ExportStatusView.describe(progress: job.progress,
                                                     remaining: job.remaining())
                         : ExportStatusView.describe(place: queue.place(of: job.id)))
                        .font(.system(size: Theme.Typography.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button { queue.cancel(job.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).clickableCursor()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel \(job.title)")
                }
            }
            if queue.jobs.count > 1 {
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel All") { queue.cancelAll() }
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 360)
    }
}
