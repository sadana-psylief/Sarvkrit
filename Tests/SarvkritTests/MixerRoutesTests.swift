import XCTest
@testable import Sarvkrit

/// Which output each app has been sent to, and what counts as having sent it anywhere.
final class MixerRoutesTests: XCTestCase {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "routes-\(UUID().uuidString)")!
    }

    private let airpods = MixerRoutes.Route(uid: "airpods-uid", name: "AirPods Pro")

    func testAnAppWithNoRouteFollowsTheSystemOutput() {
        XCTAssertNil(MixerRoutes(defaults: suite()).route(for: "com.apple.Safari"))
    }

    func testSettingARouteIsRememberedAndReadBack() {
        var r = MixerRoutes(defaults: suite())
        r.setRoute(airpods, for: "com.spotify.client")
        XCTAssertEqual(r.route(for: "com.spotify.client"), airpods)
    }

    func testSystemOutputIsTheAbsenceOfARoute() {
        var r = MixerRoutes(defaults: suite())
        r.setRoute(airpods, for: "a")
        r.setRoute(nil, for: "a")
        XCTAssertNil(r.route(for: "a"))
        XCTAssertTrue(r.routes.isEmpty)
    }

    func testResetForgetsOneAppAndResetAllForgetsEveryApp() {
        var r = MixerRoutes(defaults: suite())
        r.setRoute(airpods, for: "a")
        r.setRoute(airpods, for: "b")
        r.reset("a")
        XCTAssertNil(r.route(for: "a"))
        XCTAssertNotNil(r.route(for: "b"))
        r.resetAll()
        XCTAssertTrue(r.routes.isEmpty)
    }

    func testRoutesSurviveARelaunch() {
        // The device name is kept too, so a route to AirPods that are in their case can still be
        // shown by name rather than as an opaque UID.
        let defaults = suite()
        var r = MixerRoutes(defaults: defaults)
        r.setRoute(airpods, for: "com.spotify.client")
        XCTAssertEqual(MixerRoutes(defaults: defaults).route(for: "com.spotify.client"), airpods)
    }
}
