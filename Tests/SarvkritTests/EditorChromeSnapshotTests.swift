import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// Photographs the editor's own chrome and looks at it.
///
/// **Why this is a test and not a scratch harness.** Four real bugs in this toolbar — a caption
/// reading "in 0 sec", a tile clipped by the scroll position, a bottom bar claiming height it was
/// not using, and black-on-black icons in light mode — were invisible to every unit test and
/// obvious in a picture. The harness that produced those pictures was a separate process, and it
/// outlived the session and left a window the user could not close. Rendering through
/// `cacheDisplay` inside the test host has the same value and cannot strand a window, because
/// there is no window: the hosting view is never ordered on screen.
///
/// Writes only when `SARVKRIT_PREVIEW_DIR` is set, so a normal run stays silent.
@MainActor
final class EditorChromeSnapshotTests: XCTestCase {

    private func base() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.87, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        return try XCTUnwrap(context.makeImage())
    }

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

    /// The toolbar must be legible in both appearances. Light mode is where it was black on black.
    func testTheToolbarRendersInBothAppearances() throws {
        for tool in [ToolKind.text, .emoji] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let model = EditorDocumentModel(base: try base())
                model.tool = tool
                let view = ScreenshotEditorView(model: model,
                                                presets: BackgroundPresetStore(),
                                                onSave: {}, onSaveEditable: {}, onCopy: {})
                let rep = try snapshot(view, size: CGSize(width: 980, height: 620),
                                       appearance: appearance)
                XCTAssertGreaterThan(rep.pixelsWide, 0)
                try write(rep, named: "editor-\(tool)-\(appearance.rawValue)")
            }
        }
    }

    /// Every one of the seven, at the size they are actually picked at.
    func testTheTextStyleSwatchesRender() throws {
        let sheet = VStack(alignment: .leading, spacing: 8) {
            ForEach(TextPreset.allCases) { preset in
                TextStyleSwatch(preset: preset, accent: .blue)
            }
        }
        .padding(16)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = try snapshot(sheet, size: CGSize(width: 260, height: 300),
                                   appearance: appearance)
            try write(rep, named: "text-swatches-\(appearance.rawValue)")
        }
    }

    /// The automation list, which is only useful if the URLs in it are readable.
    func testTheAutomationSectionRenders() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rep = try snapshot(Form { CaptureAutomationSection() }.formStyle(.grouped),
                                   size: CGSize(width: 620, height: 520),
                                   appearance: appearance)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            try write(rep, named: "automation-\(appearance.rawValue)")
        }
    }

    private func write(_ rep: NSBitmapImageRep, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SARVKRIT_PREVIEW_DIR"]
        else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory)
            .appendingPathComponent("\(name).png"))
    }
}
