import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// Photographs the capture chrome that has no other way to be seen.
///
/// The text result panel and the scrolling HUD both appear only part-way through a gesture that
/// needs a real mouse, so they are the two surfaces most likely to ship looking wrong. Rendering
/// through `cacheDisplay` inside the test host cannot strand a window, because there is no window:
/// the hosting view is never ordered on screen.
@MainActor
final class CaptureChromeSnapshotTests: XCTestCase {

    private func snapshot(_ view: some View, size: CGSize,
                          appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SARVKRIT_PREVIEW_DIR"]
        else { return }
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testTheTextResultPanelRenders() throws {
        let sample = """
            Sarvkrit — the things macOS does differently
            Capture an area, a window or the whole screen.
            The screen freezes while you choose.
            """
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = try snapshot(TextResultView(text: sample, isBarcode: false, onClose: {}),
                                   size: CGSize(width: 460, height: 320),
                                   appearance: appearance)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            try write(rep, named: "ocr-\(appearance.rawValue)")
        }
    }

    func testAScannedLinkOffersToBeOpenedAndNothingElseDoes() throws {
        // The rule this pins: a bare URL gets an offer, a URL buried in prose does not — clicking
        // "Open Link" must never open something the user did not read.
        let bare = TextResultView(text: "https://sarvkrit.com/download", isBarcode: true,
                                  onClose: {})
        let buried = TextResultView(text: "see https://sarvkrit.com/download for details",
                                    isBarcode: false, onClose: {})
        let bareRep = try snapshot(bare, size: CGSize(width: 460, height: 260), appearance: .darkAqua)
        let buriedRep = try snapshot(buried, size: CGSize(width: 460, height: 260),
                                     appearance: .darkAqua)
        try write(bareRep, named: "ocr-link")
        XCTAssertNotEqual(bareRep.representation(using: .png, properties: [:]),
                          buriedRep.representation(using: .png, properties: [:]),
                          "both rendered the same, so the Open Link button is not conditional")
    }

    func testTheScrollHUDRendersInBothItsStates() throws {
        let model = ScrollCaptureHUDModel()
        model.frameCount = 7
        let calm = try snapshot(ScrollCaptureHUDView(model: model, onFinish: {}, onCancel: {}),
                                size: CGSize(width: 400, height: 90), appearance: .darkAqua)
        try write(calm, named: "scroll-hud")

        model.missedAFrame = true
        let warning = try snapshot(ScrollCaptureHUDView(model: model, onFinish: {}, onCancel: {}),
                                   size: CGSize(width: 400, height: 90), appearance: .darkAqua)
        try write(warning, named: "scroll-hud-warning")
        XCTAssertNotEqual(calm.representation(using: .png, properties: [:]),
                          warning.representation(using: .png, properties: [:]),
                          "the warning state looks identical to the calm one")
    }

    func testTheConfirmBarRenders() throws {
        for mode in [CaptureMode.area, .scrolling, .textRecognition] {
            let bar = AllInOnePickerView(
                memory: CaptureModeMemory(mode: mode, pixelSize: nil, aspectLocked: false),
                timerSeconds: 0,
                primary: .init(title: mode.confirmVerb, action: {}),
                onPick: { _, _ in }, onCancel: {})
            let rep = try snapshot(bar, size: CGSize(width: 900, height: 120),
                                   appearance: .darkAqua)
            try write(rep, named: "confirm-bar-\(mode.rawValue)")
            XCTAssertGreaterThan(rep.pixelsWide, 0)
        }
    }
}
