import CoreAudio
import XCTest
@testable import Sarvkrit

/// Which apps get a tap, and which output each tap plays on. Pure, so "AirPods went back in the
/// case while Spotify was routed to them" is a table row rather than a cable-pulling session.
final class MixerPlanTests: XCTestCase {

    private func device(
        _ id: AudioObjectID, _ uid: String,
        output: Bool = true, aggregate: Bool = false
    ) -> AudioDevice {
        AudioDevice(
            id: id, uid: uid, name: uid,
            hasOutput: output, hasInput: !output, isAggregate: aggregate
        )
    }

    private lazy var speakers = device(1, "speakers")
    private lazy var airpods = device(2, "airpods")
    private lazy var mic = device(3, "mic", output: false)
    private lazy var loopback = device(4, "loopback", aggregate: true)

    private var levels = MixerLevels(defaults: UserDefaults(suiteName: "plan-\(UUID().uuidString)")!)
    private var routes = MixerRoutes(defaults: UserDefaults(suiteName: "plan-\(UUID().uuidString)")!)

    private func route(_ bundleID: String, to device: AudioDevice) {
        routes.setRoute(.init(uid: device.uid, name: device.name), for: bundleID)
    }

    private func plan(playing: [String], outputs: [AudioDevice]? = nil) -> [String: String] {
        MixerPlan.desiredTaps(
            playing: playing,
            levels: levels,
            routes: routes,
            outputs: outputs ?? [speakers, airpods, mic, loopback],
            defaultOutputUID: speakers.uid
        )
    }

    func testAnUntouchedAppIsNeverTapped() {
        XCTAssertEqual(plan(playing: ["a"]), [:])
    }

    func testATurnedDownAppIsTappedOnTheSystemOutput() {
        levels.setLevel(0.4, for: "a")
        XCTAssertEqual(plan(playing: ["a"]), ["a": "speakers"])
    }

    func testARoutedAppIsTappedOnItsDeviceEvenAtFullVolume() {
        route("a", to: airpods)
        XCTAssertEqual(plan(playing: ["a"]), ["a": "airpods"])
    }

    func testARouteAndALevelTogetherPlayOnTheRoutedDevice() {
        route("a", to: airpods)
        levels.setLevel(0.4, for: "a")
        XCTAssertEqual(plan(playing: ["a"]), ["a": "airpods"])
    }

    func testARouteToTheSystemOutputAtFullVolumeNeedsNoTap() {
        // Tapping would change nothing the user can hear, and costs a trip through us.
        route("a", to: speakers)
        XCTAssertEqual(plan(playing: ["a"]), [:])
    }

    func testADisconnectedDeviceFallsBackToTheSystemOutput() {
        route("a", to: airpods)
        route("b", to: airpods)
        levels.setLevel(0.4, for: "b")
        // At full volume the fallback is the system output anyway, so no tap at all.
        XCTAssertEqual(plan(playing: ["a", "b"], outputs: [speakers]), ["b": "speakers"])
    }

    func testTheRouteIsKeptSoTheAppReturnsWhenTheDeviceDoes() {
        route("a", to: airpods)
        _ = plan(playing: ["a"], outputs: [speakers])
        XCTAssertEqual(plan(playing: ["a"]), ["a": "airpods"])
    }

    func testRoutesToAggregatesOrInputOnlyDevicesAreIgnored() {
        route("a", to: loopback)
        route("b", to: mic)
        XCTAssertEqual(plan(playing: ["a", "b"]), [:])
    }

    func testAnAppThatIsNotPlayingIsNotTapped() {
        route("a", to: airpods)
        levels.setLevel(0.4, for: "b")
        XCTAssertEqual(plan(playing: []), [:])
    }

    func testNoDefaultOutputMeansOnlyRoutedAppsCanBeTapped() {
        route("a", to: airpods)
        levels.setLevel(0.4, for: "b")
        let result = MixerPlan.desiredTaps(
            playing: ["a", "b"], levels: levels, routes: routes,
            outputs: [airpods], defaultOutputUID: nil
        )
        XCTAssertEqual(result, ["a": "airpods"])
    }
}
