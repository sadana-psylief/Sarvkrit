import XCTest
@testable import Sarvkrit

/// Telling "Music launched itself" from "I opened Music".
///
/// The requirement is explicit: stop it bursting in when headphones connect, but leave a deliberate
/// launch alone. Quitting every launch would be trivial and useless.
final class MusicLaunchDecisionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Blocking a self-launch

    func testALaunchRightAfterADeviceChangeIsBlocked() {
        XCTAssertEqual(
            MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: now.addingTimeInterval(-0.2)),
            .block
        )
    }

    func testALaunchAtTheEdgeOfTheWindowIsStillBlocked() {
        let change = now.addingTimeInterval(-MusicLaunchDecision.window)
        XCTAssertEqual(MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: change), .block)
    }

    func testALaunchSimultaneousWithTheDeviceChangeIsBlocked() {
        XCTAssertEqual(MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: now), .block)
    }

    // MARK: - Letting a deliberate launch through

    func testALaunchWellAfterADeviceChangeIsAllowed() {
        // Connect headphones, listen to something else for a minute, then open Music yourself.
        let change = now.addingTimeInterval(-60)
        XCTAssertEqual(MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: change), .allow)
    }

    func testALaunchJustPastTheWindowIsAllowed() {
        let change = now.addingTimeInterval(-(MusicLaunchDecision.window + 0.01))
        XCTAssertEqual(MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: change), .allow)
    }

    func testALaunchWithNoDeviceChangeEverIsAllowed() {
        // Nothing happened to the hardware, so nothing can have triggered it.
        XCTAssertEqual(MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: nil), .allow)
    }

    func testALaunchBeforeTheDeviceChangeIsAllowed() {
        // The two notifications can arrive close together and out of order. A launch that happened
        // first cannot have been caused by a change that happened after it.
        let change = now.addingTimeInterval(1)
        XCTAssertEqual(MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: change), .allow)
    }

    func testTheWindowIsShortEnoughToBeSafe() {
        // Guards the tuning itself. A long window swallows deliberate launches, which is the error
        // that actually annoys — the app then seems broken rather than helpful.
        XCTAssertLessThanOrEqual(MusicLaunchDecision.window, 5)
        XCTAssertGreaterThan(MusicLaunchDecision.window, 0)
    }

    func testTheWindowIsConfigurableForTesting() {
        let change = now.addingTimeInterval(-10)
        XCTAssertEqual(
            MusicLaunchDecision.verdict(launchedAt: now, lastDeviceChange: change, window: 30),
            .block
        )
    }

    // MARK: - Which app

    func testBothMusicAndItunesAreRecognised() {
        // A Mac upgraded in place from an old enough macOS still has the iTunes bundle id.
        XCTAssertTrue(MusicLaunchDecision.isMusic(bundleID: "com.apple.Music"))
        XCTAssertTrue(MusicLaunchDecision.isMusic(bundleID: "com.apple.iTunes"))
    }

    func testOtherAppsAreNotMusic() {
        // Spotify launching on headphone connect is Spotify's business, not ours to quit.
        XCTAssertFalse(MusicLaunchDecision.isMusic(bundleID: "com.spotify.client"))
        XCTAssertFalse(MusicLaunchDecision.isMusic(bundleID: "com.apple.Safari"))
        XCTAssertFalse(MusicLaunchDecision.isMusic(bundleID: nil))
    }
}
