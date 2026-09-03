import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// TEMPORARY: renders capture chrome to /tmp so it can be looked at. Deleted after review.
@MainActor
final class TEMP_ChromePreview: XCTestCase {

    private var outputDirectory: URL {
        URL(fileURLWithPath: "/private/tmp/claude-501/-Users-apple-Documents-Dev-sarvkrit/f4bc2aed-e747-44ac-9bf7-06120fd6fa4c/scratchpad")
    }

    private func write<V: View>(_ view: V, named name: String, scale: CGFloat = 2) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            XCTFail("no image for \(name)"); return
        }
        let data = try XCTUnwrap(CaptureDocumentFile.png(from: image))
        try data.write(to: outputDirectory.appendingPathComponent(name))
        print("PREVIEW wrote \(name) \(image.width)x\(image.height)")
    }

    func testRenderAllInOneBar() throws {
        // Over a photographic-ish backdrop, because that is what it actually floats on and a
        // translucent bar judged against flat grey tells you nothing.
        let backdrop = LinearGradient(
            colors: [Color(red: 0.10, green: 0.06, blue: 0.04),
                     Color(red: 0.02, green: 0.02, blue: 0.03),
                     Color(red: 0.15, green: 0.09, blue: 0.03)],
            startPoint: .topLeading, endPoint: .bottomTrailing)

        let view = ZStack {
            backdrop
            AllInOnePickerView(
                memory: CaptureModeMemory(mode: .window, pixelSize: CGSize(width: 608, height: 455),
                                          aspectLocked: false),
                timerSeconds: 0,
                onPick: { _, _ in }, onCancel: {})
        }
        .frame(width: 1000, height: 220)

        try write(view, named: "hud-allinone.png")
    }
}
