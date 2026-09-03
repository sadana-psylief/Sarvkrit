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
    private var lastEventAt: Date?
    private var lastCaptureAt: Date?
    private var completion: ((CGImage?) -> Void)?
    private var isCapturing = false

    private static let frameLimit = 40

    var isRunning: Bool { hud != nil }

    /// Starts watching the user's scrolling over `region`.
    func start(region: CGRect,
               display: DisplaySnapshotGeometry,
               capturer: ScreenCapturing,
               options: CaptureOptions,
               completion: @escaping (CGImage?) -> Void) {
        stop()
        self.region = region
        self.display = display
        self.capturer = capturer
        self.options = options
        self.completion = completion
        self.images = []

        showHUD()
        // The first frame now, so there is something to match against.
        Task { await captureFrame() }

        // A *mouse* monitor, which needs no permission — unlike a key monitor or an event tap.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastEventAt = Date() }
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !isCapturing, images.count < Self.frameLimit else { return }
        guard ScrollQuiescence.shouldCapture(lastEventAt: lastEventAt,
                                             lastCaptureAt: lastCaptureAt,
                                             now: Date()) else { return }
        Task { await captureFrame() }
    }

    private func captureFrame() async {
        guard let capturer, let display, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        lastCaptureAt = Date()

        do {
            // The HUD is one of our own windows, so the filter already excludes it — the region
            // being captured can sit underneath it without the prompt appearing in the result.
            let full = try await capturer.captureDisplay(display, options: options)
            let pixels = CaptureGeometry.pixelRect(forGlobalRect: region, in: display)
            guard let cropped = full.cropping(to: pixels.integral) else { return }
            images.append(cropped)
            refreshHUD()
        } catch {
            log.error("scroll frame failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stitches what was captured and hands it back.
    func finish() {
        let captured = images
        let completion = self.completion
        stop()

        guard captured.count > 1 else {
            // One frame is not a scrolling capture, but it is still a capture — returning it beats
            // telling the user their screenshot went nowhere.
            completion?(captured.first)
            return
        }

        let frames = captured.map {
            ScrollFrame(lines: ImageLineSignature.signatures(of: $0, axis: .vertical),
                        width: $0.width, height: $0.height)
        }
        let plan = ScrollStitcher.plan(frames: frames, axis: .vertical,
                                       options: ScrollStitcher.Options())
        if case .noOverlapFound(let index) = plan.endedBecause {
            log.error("scroll stitch stopped: no overlap at frame \(index, privacy: .public)")
        }
        completion?(ScrollStitcher.render(plan, images: captured, axis: .vertical))
    }

    func cancel() {
        let completion = self.completion
        stop()
        completion?(nil)
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
        refreshHUD()
        panel.orderFrontRegardless()
    }

    private func refreshHUD() {
        hud?.contentView = NSHostingView(rootView: ScrollCaptureHUDView(
            frameCount: images.count,
            onFinish: { [weak self] in self?.finish() },
            onCancel: { [weak self] in self?.cancel() }))
    }
}
