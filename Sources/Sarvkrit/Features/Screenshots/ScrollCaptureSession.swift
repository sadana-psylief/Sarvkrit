import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import os

/// A scrolling capture, driven by the user's own scrolling.
///
/// **Observation rather than synthetic scrolling, and that is a permissions decision as much as a
/// reliability one.** Posting scroll events would need Accessibility, which this feature
/// deliberately does not declare — `FeatureCategoryTests` asserts that only `EventTapFeature`s do.
/// A global *mouse* monitor needs no grant at all, the same asymmetry `ShelfDragMonitor` relies
/// on. It also degrades better: if the stitch fails, the user simply scrolls again, where a
/// synthetic driver fighting momentum and lazy-loading has no such recovery.
@MainActor
final class ScrollCaptureSession: NSObject {
    static let shared = ScrollCaptureSession()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    private var monitor: Any?
    private var timer: Timer?
    private var hud: FloatingPanel?

    private var capturer: ScreenCapturing?
    private var options = CaptureOptions()
    private var region: CGRect = .zero
    private var display: DisplaySnapshotGeometry?

    private var images: [CGImage] = []
    private let hudModel = ScrollCaptureHUDModel()
    /// Scroll distance since the last captured frame, in points. Capturing on distance as well as
    /// on pauses is what makes overlap structural instead of a matter of how gently someone
    /// scrolled — one flick used to move a whole viewport between pauses, leaving consecutive
    /// frames with no rows in common and nothing for the stitcher to match.
    private var scrolledSinceCapture: CGFloat = 0
    private var lastEventAt: Date?
    private var lastCaptureAt: Date?
    private var completion: ((Outcome) -> Void)?
    /// Line signatures, computed as each frame arrives.
    ///
    /// They used to be computed for every frame at once in `finish()` — per-row allocations across
    /// up to forty Retina frames, i.e. seconds of frozen UI with no indication anything was
    /// happening. One frame's worth spread across the scroll is work nobody notices.
    private var frames: [ScrollFrame] = []

    /// How a session ended, so the caller can tell a cancel from a failure.
    ///
    /// Everything used to come back as `nil`, and `nil` means "cancelled — no toast". A
    /// forty-frame capture whose stitch failed was therefore indistinguishable from pressing
    /// Escape: no image, no message, nothing.
    enum Outcome {
        case stitched(CGImage)
        case cancelled
        case failed(reason: String)
    }
    private var isCapturing = false

    private static let frameLimit = 40
    /// One set of thresholds, used both for the live warning and for the final stitch — a HUD
    /// that said "fine" and then failed would be worse than no HUD.
    private static let stitchOptions = ScrollStitcher.Options()

    var isRunning: Bool { hud != nil }

    /// Starts watching the user's scrolling over `region`.
    func start(region: CGRect,
               display: DisplaySnapshotGeometry,
               capturer: ScreenCapturing,
               options: CaptureOptions,
               completion: @escaping (Outcome) -> Void) {
        stop()
        self.region = region
        self.display = display
        self.capturer = capturer
        self.options = options
        self.completion = completion
        self.images = []
        self.frames = []
        self.scrolledSinceCapture = 0
        self.hudModel.frameCount = 0
        self.hudModel.missedAFrame = false

        showHUD()
        // The first frame now, so there is something to match against.
        Task { await captureFrame() }

        // A *mouse* monitor, which needs no permission — unlike a key monitor or an event tap.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastEventAt = Date()
                self.scrolledSinceCapture += abs(event.scrollingDeltaY)
            }
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !isCapturing else { return }
        // The cap ends the session rather than merely stopping capture. It used to leave the HUD
        // frozen at "40 frames captured" with scrolling doing nothing and no way to tell why.
        guard images.count < Self.frameLimit else {
            finish()
            return
        }
        // Either the user paused, or they have scrolled far enough that waiting for a pause would
        // cost the overlap.
        let travelled = scrolledSinceCapture >= overlapBudget
        guard travelled || ScrollQuiescence.shouldCapture(lastEventAt: lastEventAt,
                                                          lastCaptureAt: lastCaptureAt,
                                                          now: Date()) else { return }
        Task { await captureFrame() }
    }

    /// How far the content may move before a frame is forced.
    ///
    /// Half the region keeps half of it in common with the frame before, which is comfortably
    /// above the stitcher's minimum overlap and leaves room for the page to have shifted a little
    /// more than the wheel said it would.
    private var overlapBudget: CGFloat { max(40, region.height * 0.5) }

    private func captureFrame() async {
        guard let capturer, let display, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        lastCaptureAt = Date()
        scrolledSinceCapture = 0

        do {
            // The HUD is one of our own windows, so the filter already excludes it — the region
            // being captured can sit underneath it without the prompt appearing in the result.
            let full = try await capturer.captureDisplay(display, options: options)
            let pixels = CaptureGeometry.pixelRect(forGlobalRect: region, in: display)
            guard let cropped = full.cropping(to: pixels.integral) else {
                // Logged, where it used to vanish. A silent zero-frame session that then returns
                // nil is indistinguishable from a cancel, which is the worst way to fail.
                log.error("scroll frame fell outside the captured bitmap: \(String(describing: pixels), privacy: .public)")
                return
            }
            images.append(cropped)
            let frame = ScrollFrame(
                lines: ImageLineSignature.signatures(of: cropped, axis: .vertical),
                width: cropped.width, height: cropped.height)
            // Checked as it arrives, not at the end. Telling someone their frames did not join
            // *after* they have finished scrolling is telling them too late to do anything about
            // it; the whole value of the warning is that it appears while they can still slow
            // down. One offset search over line hashes is cheap enough to run per frame.
            if let previous = frames.last {
                let match = ScrollStitcher.offset(of: frame.lines, in: previous.lines,
                                                  minimumOverlap: Self.stitchOptions.minimumOverlap)
                hudModel.missedAFrame = match == nil
                    || match!.margin < Self.stitchOptions.minimumMargin
            }
            frames.append(frame)
            hudModel.frameCount = images.count
        } catch {
            log.error("scroll frame failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stitches what was captured and hands it back.
    func finish() {
        let captured = images
        let signatures = frames
        let completion = self.completion
        stop()

        guard captured.count > 1 else {
            // One frame is not a scrolling capture, but it is still a capture — returning it beats
            // telling the user their screenshot went nowhere.
            guard let only = captured.first else {
                completion?(.failed(reason: "Nothing was captured — try scrolling the page"))
                return
            }
            completion?(.stitched(only))
            return
        }

        let plan = ScrollStitcher.plan(frames: signatures, axis: .vertical,
                                       options: Self.stitchOptions)
        if case .noOverlapFound(let index) = plan.endedBecause {
            log.error("scroll stitch stopped: no overlap at frame \(index, privacy: .public)")
        }
        guard let stitched = ScrollStitcher.render(plan, images: captured, axis: .vertical) else {
            completion?(.failed(reason: "Couldn't join the frames — scroll more slowly next time"))
            return
        }
        completion?(.stitched(stitched))
    }

    func cancel() {
        let completion = self.completion
        stop()
        completion?(.cancelled)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        hud?.orderOut(nil)
        hud = nil
        completion = nil
        images = []
        frames = []
        lastEventAt = nil
        lastCaptureAt = nil
    }

    // MARK: - HUD

    private func showHUD() {
        let size = CGSize(width: 400, height: 76)
        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = FloatingPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2,
                                y: visible.minY + 40,
                                width: size.width, height: size.height),
            style: .init(level: .modalPanel, acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true))
        hud = panel
        panel.contentView = buildHUDContent()
        // Key, not merely front: Done is the default button and Cancel the escape one, and
        // neither did anything until the panel had been clicked once.
        panel.makeKeyAndOrderFront(nil)
    }

    /// Built once. Rebuilding it on every frame destroyed a mouse-down in progress on Done.
    private func buildHUDContent() -> NSView {
        NSHostingView(rootView: ScrollCaptureHUDView(
            model: hudModel,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }))
    }
}
