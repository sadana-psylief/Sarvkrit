import XCTest
@testable import Sarvkrit

final class CaptureFilenameTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
    private let utc = TimeZone(identifier: "UTC")!

    private func make(_ pattern: String, mode: CaptureMode = .area, counter: Int = 0) -> String {
        CaptureFilename.make(pattern: pattern, mode: mode, date: date,
                             counter: counter, timeZone: utc)
    }

    func testTheDefaultPatternExpands() {
        XCTAssertEqual(make(CaptureFilename.defaultPattern),
                       "Screenshot 2023-11-14 at 22.13.20")
    }

    func testTheTimeUsesDotsNotColons() {
        // A colon is a path separator to the Finder: it renders the name oddly in the sidebar and
        // breaks anything scripting over the folder.
        XCTAssertFalse(make("{time}").contains(":"))
        XCTAssertEqual(make("{time}"), "22.13.20")
    }

    func testEveryTokenIsSubstituted() {
        XCTAssertEqual(make("{mode}-{n}", mode: .window, counter: 7), "Window-7")
        for token in CaptureFilename.tokens {
            XCTAssertFalse(make(token).contains("{"), "\(token) was not substituted")
        }
    }

    func testAPathSeparatorCannotEscapeTheFolder() {
        // The case that matters: a name with a separator doesn't fail, it writes elsewhere.
        XCTAssertEqual(CaptureFilename.sanitised("../../etc/passwd"), "etc-passwd")
        XCTAssertFalse(make("shots/today").contains("/"))
        XCTAssertEqual(make("shots/today"), "shots-today")
    }

    func testALeadingDotCannotProduceAnInvisibleFile() {
        XCTAssertEqual(CaptureFilename.sanitised(".hidden"), "hidden")
    }

    func testAnEmptyPatternStillProducesAName() {
        // Otherwise the file is called ".png" and vanishes from the Finder.
        XCTAssertEqual(make(""), "Screenshot")
        XCTAssertEqual(make("///"), "Screenshot")
    }

    func testUnknownTokensAreLeftAlone() {
        // Better a visible "{nope}" in the name than a silently dropped one the user can't debug.
        XCTAssertEqual(make("shot {nope}"), "shot {nope}")
    }

    func testASecondCaptureInTheSameSecondDoesNotOverwriteTheFirst() {
        // A burst of ⌃⇧A is ordinary, and the default pattern is only accurate to the second.
        let directory = URL(fileURLWithPath: "/tmp/shots")
        let taken: Set<String> = ["/tmp/shots/Shot.png"]
        let url = CaptureFilename.unique(base: "Shot", extension: "png", in: directory) {
            taken.contains($0.path)
        }
        XCTAssertEqual(url.lastPathComponent, "Shot 2.png")
    }

    func testItKeepsCountingPastTheSecondCollision() {
        let directory = URL(fileURLWithPath: "/tmp/shots")
        let taken: Set<String> = ["/tmp/shots/Shot.png", "/tmp/shots/Shot 2.png",
                                  "/tmp/shots/Shot 3.png"]
        let url = CaptureFilename.unique(base: "Shot", extension: "png", in: directory) {
            taken.contains($0.path)
        }
        XCTAssertEqual(url.lastPathComponent, "Shot 4.png")
    }

    func testAFreeNameIsUsedAsIs() {
        let url = CaptureFilename.unique(base: "Shot", extension: "png",
                                         in: URL(fileURLWithPath: "/tmp")) { _ in false }
        XCTAssertEqual(url.lastPathComponent, "Shot.png")
    }

    func testItGivesUpRatherThanSpinning() {
        // Pathological, but an infinite loop here would hang the capture path entirely.
        let url = CaptureFilename.unique(base: "Shot", extension: "png",
                                         in: URL(fileURLWithPath: "/tmp")) { _ in true }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Shot "))
    }
}
