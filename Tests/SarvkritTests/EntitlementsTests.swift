import XCTest
@testable import Sarvkrit

/// What the app is allowed to ask for.
///
/// **This suite exists because of a silent failure.** Screen Recording's camera looked correct from
/// every angle — the usage string was present, the code requested access, the UI reported the
/// result honestly — and macOS never showed the prompt. Under Hardened Runtime the entitlement is
/// required *to ask*, and without it `requestAccess` returns denied having asked nobody. The user
/// is then sent to System Settings to find an app that is not listed there, because it never got
/// far enough to be added.
///
/// Nothing about that is visible in Swift, so it is asserted against the built bundle instead.
final class EntitlementsTests: XCTestCase {

    private func entitlements() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Sarvkrit", withExtension: "entitlements")
            ?? Bundle(for: Self.self).bundleURL
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sarvkrit.app/Contents/Resources/Sarvkrit.entitlements"),
            "the entitlements file is not in the bundle")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Read from the source file rather than the bundle: entitlements are baked into the signature
    /// at build time and are not copied in as a resource, so this is the only place to check them
    /// without shelling out to codesign.
    private func sourceEntitlements() throws -> [String: Any] {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/Sarvkrit/Resources/Sarvkrit.entitlements")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheCameraEntitlementIsPresent() throws {
        XCTAssertEqual(try sourceEntitlements()["com.apple.security.device.camera"] as? Bool, true,
                       "without this, macOS will not even show the camera prompt")
    }

    func testTheMicrophoneEntitlementIsPresent() throws {
        XCTAssertEqual(try sourceEntitlements()["com.apple.security.device.audio-input"] as? Bool,
                       true, "without this, macOS will not even show the microphone prompt")
    }

    func testAppleEventsAutomationIsStillThere() throws {
        XCTAssertEqual(
            try sourceEntitlements()["com.apple.security.automation.apple-events"] as? Bool, true)
    }

    /// **The one that must never appear.** Event taps and the Accessibility API are incompatible
    /// with the App Sandbox, and the README says so at length: the sandbox is off precisely because
    /// this key is absent, and there is no build setting to flip. Adding it would break Finder
    /// Cut & Paste, Window Management and the clipboard's global shortcuts at once.
    func testTheAppSandboxIsNotEnabled() throws {
        XCTAssertNil(try sourceEntitlements()["com.apple.security.app-sandbox"],
                     "the App Sandbox must stay off — see the README")
    }

    /// A usage string is the other half; neither works without the other.
    func testEveryDevicePermissionHasItsExplanation() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSSpeechRecognitionUsageDescription"] {
            let text = info[key] as? String ?? ""
            XCTAssertFalse(text.isEmpty, "\(key) is missing from Info.plist")
        }
    }

    /// The URL name is what System Settings looks the app up by; a stale bundle id there logs an
    /// error in the privacy pane every time somebody opens it to grant a permission.
    func testTheURLNameMatchesTheBundleIdentifier() throws {
        let types = Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        for type in types {
            guard let name = type["CFBundleURLName"] as? String else { continue }
            XCTAssertTrue(name.hasPrefix(AppIdentity.bundleID),
                          "\(name) does not belong to \(AppIdentity.bundleID)")
        }
    }
}
