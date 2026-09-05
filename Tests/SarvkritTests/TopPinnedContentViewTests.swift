import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// The one thing standing between an animated panel resize and the bug it used to be.
///
/// These use a real `NSPanel` with a real `NSHostingView`, parked far off any screen the way
/// `TrayPanelRenderTests` does, because the behaviour under test is `NSHostingView`'s own layout
/// and a windowless view does not perform it.
@MainActor
final class TopPinnedContentViewTests: XCTestCase {

    private let contentHeight: CGFloat = 350
    private let width: CGFloat = 420

    /// A `MenuBarWindowProbe` stands in for the content, because it is a real `NSView` whose
    /// position can be read. A SwiftUI `Color` leaves no backing view to measure.
    private func panel(height: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: -30000, y: -30000, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(
            rootView: VStack(spacing: 0) { Color.clear.frame(height: contentHeight) }
                .frame(width: width)
                .background(MenuBarWindowProbe(onWindow: { _ in }, onHeight: { _ in })))
        return panel
    }

    private func marker(in view: NSView) -> NSView? {
        if view is MenuBarWindowProbe.ProbeView { return view }
        for sub in view.subviews { if let found = marker(in: sub) { return found } }
        return nil
    }

    private func topInset(of view: NSView, in container: NSView) -> CGFloat {
        let f = view.convert(view.bounds, to: container)
        return container.isFlipped ? f.minY - container.bounds.minY : container.bounds.maxY - f.maxY
    }

    // MARK: - The behaviour that makes an animated resize impossible without this

    func testWithoutTheContainerAHostingViewCentresItsRoot() throws {
        // Not a test of our code — a test of the premise, so that if a future macOS stops centring,
        // this fails and tells you the container can go.
        let panel = self.panel(height: 533)
        defer { panel.close() }
        let host = try XCTUnwrap(panel.contentView)
        host.layoutSubtreeIfNeeded()

        let root = try XCTUnwrap(marker(in: host))
        XCTAssertEqual(topInset(of: root, in: host), (533 - contentHeight) / 2, accuracy: 1,
                       "expected the root centred, which is what the container exists to prevent")
    }

    // MARK: - What the container promises

    func testTheContentStaysAgainstTheTopEdgeWhateverTheWindowDoes() throws {
        let panel = self.panel(height: 533)
        defer { panel.close() }
        let container = try XCTUnwrap(TopPinnedContentView.install(in: panel))
        container.contentHeight = contentHeight

        // Every height an animated 533 -> 350 shrink passes through, and the grow back up.
        for height in [533, 500, 450, 400, 350, 300, 400, 533] as [CGFloat] {
            panel.setFrame(NSRect(x: -30000, y: -30000, width: width, height: height), display: false)
            panel.layoutIfNeeded()
            container.layoutSubtreeIfNeeded()

            let content = try XCTUnwrap(container.content)
            XCTAssertEqual(topInset(of: content, in: container), 0, accuracy: 0.5,
                           "content moved off the top edge at window height \(height)")
            XCTAssertEqual(content.frame.height, contentHeight, accuracy: 0.5,
                           "content was resized by the window at height \(height)")
        }
    }

    func testInstallingItChangesNobodysIdeaOfHowBigTheWindowShouldBe() throws {
        // `MenuBarExtra` sizes and positions its own window from the content view. If interposing
        // this changed `fittingSize`, it would break the panel exactly as the SwiftUI-side
        // attempts did.
        let panel = self.panel(height: 533)
        defer { panel.close() }
        let before = try XCTUnwrap(panel.contentView).fittingSize

        let container = try XCTUnwrap(TopPinnedContentView.install(in: panel))
        XCTAssertEqual(container.fittingSize.height, before.height, accuracy: 0.5)
        XCTAssertEqual(container.fittingSize.width, before.width, accuracy: 0.5)
    }

    func testInstallingIsIdempotent() throws {
        // The probe reports its window on every pass through `viewDidMoveToWindow`, so this is
        // called repeatedly; nesting a container inside a container would add an untracked view
        // per presentation.
        let panel = self.panel(height: 533)
        defer { panel.close() }
        let first = try XCTUnwrap(TopPinnedContentView.install(in: panel))
        let second = try XCTUnwrap(TopPinnedContentView.install(in: panel))

        XCTAssertTrue(first === second)
        XCTAssertEqual(first.subviews.count, 1)
    }

    func testTheContentKeepsTakingClicks() throws {
        // The panel is full of live switches. A container that swallowed a click would be worse
        // than the drift it removes.
        let panel = self.panel(height: 533)
        defer { panel.close() }
        let container = try XCTUnwrap(TopPinnedContentView.install(in: panel))
        container.contentHeight = contentHeight
        container.layoutSubtreeIfNeeded()

        let hit = container.hitTest(NSPoint(x: width / 2, y: container.bounds.midY))
        XCTAssertNotNil(hit, "clicks stopped reaching the content")
        XCTAssertFalse(hit === container, "the container took the click itself")
    }
}
