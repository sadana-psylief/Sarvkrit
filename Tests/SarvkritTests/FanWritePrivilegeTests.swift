import XCTest
@testable import Sarvkrit

/// A boundary that is otherwise only a convention.
///
/// The SMC layer is compiled into the app *and* into the root helper, so the app can see the code
/// that writes fan keys even though it must never call it. Keeping that true is what stops a bug
/// in the app — which has no privileges and no business holding a fan — from becoming a fan stuck
/// at one speed. A comment would not survive a refactor; this does.
final class FanWritePrivilegeTests: XCTestCase {

    private func appSources() throws -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SarvkritTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/Sarvkrit")

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 50, "found too few sources — did the layout move?")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func testNothingInTheAppEverConstructsTheFanWriter() throws {
        for file in try appSources() {
            XCTAssertFalse(file.text.contains("SMCFanWriter"),
                           "\(file.path) references the fan writer, which is the helper's alone")
        }
    }

    func testNothingInTheAppEverWritesAnSMCKey() throws {
        for file in try appSources() {
            XCTAssertFalse(file.text.contains(".writeDouble("),
                           "\(file.path) writes an SMC key; only the root helper may do that")
        }
    }
}
