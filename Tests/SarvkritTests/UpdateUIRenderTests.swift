import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// Actually renders the panes the update notice touches.
///
/// The logic tests prove the decision is right; these prove the views that show it can be built
/// and laid out at all. Everything here is stock SwiftUI, which is exactly why it's worth
/// checking cheaply: a Section/Form arrangement that doesn't type-check the way it reads, or a
/// nil unwrap on a release with no notes, would otherwise only show up when someone opened
/// Settings on the day a release happened to land.
@MainActor
final class UpdateUIRenderTests: XCTestCase {
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "ai.psylief.sarvkrit.render.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func writeFeed(_ json: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(UpdateFeedStore.feedFileName))
    }

    private func makeState() -> AppState {
        AppState(
            features: [],
            store: FeatureStore(defaults: defaults),
            updates: UpdateChecker(
                store: UpdateFeedStore(directory: directory),
                currentVersion: AppVersion("1.0"),
                defaults: defaults),
            defaults: defaults)
    }

    /// Builds the view and forces a layout pass. A crash or an unsatisfiable layout fails here.
    private func render<V: View>(_ view: V, width: CGFloat = 420, height: CGFloat = 600) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testSettingsRendersWithAnUpdateAvailable() throws {
        try writeFeed(#"{"tag_name":"v9.9.9","name":"Sarvkrit 9.9.9","body":"- one\n- **two**","html_url":"https://example.com/r"}"#)
        let state = makeState()
        guard case .available = state.updates.state else { return XCTFail("expected an update") }
        render(GeneralSettingsView().environmentObject(state))
    }

    func testSettingsRendersWithNoUpdate() throws {
        try writeFeed(#"{"tag_name":"v1.0"}"#)
        render(GeneralSettingsView().environmentObject(makeState()))
    }

    /// The state the app is in before the check has ever run — the first launch of any install.
    func testSettingsRendersWithNoFeedAtAll() {
        render(GeneralSettingsView().environmentObject(makeState()))
    }

    func testAboutRendersInEveryUpdateState() throws {
        render(AboutView().environmentObject(makeState()))
        try writeFeed(#"{"tag_name":"v1.0"}"#)
        render(AboutView().environmentObject(makeState()))
        try writeFeed(#"{"tag_name":"v9.9.9"}"#)
        render(AboutView().environmentObject(makeState()))
    }

    /// A release published with no notes and no URL — every optional at once.
    func testNoticeRendersForAReleaseWithNothingButATag() {
        render(UpdateNoticeView(
            release: LatestRelease(tagName: "v2.0", name: nil, body: nil, htmlURL: nil, publishedAt: nil),
            onSkip: {}))
    }

    func testNoticeRendersWithMarkdownNotesAndALink() {
        render(UpdateNoticeView(
            release: LatestRelease(
                tagName: "v2.0",
                name: "Sarvkrit 2.0",
                body: String(repeating: "**bold** and `code` and a list\n- item\n", count: 200),
                htmlURL: "https://github.com/sadana-psylief/Sarvkrit/releases/tag/v2.0",
                publishedAt: "2026-09-03T17:19:01Z"),
            onSkip: {}))
    }

    func testBannerRenders() {
        render(UpdateBanner(version: "9.9.9", onOpen: {}), width: Theme.Size.dropdownWidth, height: 120)
    }

    /// The command the notice hands over has to be exactly the one the README and the site
    /// document, character for character — it is the entire update path.
    func testInstallCommandIsTheDocumentedOne() {
        XCTAssertEqual(UpdateNoticeView.installCommand, "curl -fsSL https://sarvkrit.com/install | sh")
    }
}
