import Security
import XCTest
@testable import Sarvkrit

/// That the shipped helper is where the root script looks, and passes the check it performs.
///
/// The unit tests are hosted *inside* Sarvkrit.app, so `Bundle.main` here is the real app bundle.
/// Every failure this catches is otherwise invisible until a user has typed their password and
/// got nothing: a helper built to the wrong subfolder, an unsigned copy, a wrong team, or a
/// binary whose identifier does not match because its Info.plist section never got generated.
/// The script exits 3 and says nothing. This says which.
final class FanHelperBundleTests: XCTestCase {
    private func appBundle() throws -> Bundle {
        let bundle = Bundle.main
        try XCTSkipUnless(
            bundle.bundleIdentifier == AppIdentity.bundleID,
            "not hosted in Sarvkrit.app — nothing to check")
        return bundle
    }

    private func helperURL() throws -> URL {
        try appBundle().bundleURL.appendingPathComponent(FanHelperScript.bundledPath)
    }

    func testTheHelperShipsWhereTheRootScriptExpectsIt() throws {
        let url = try helperURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "no helper at \(FanHelperScript.bundledPath)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path),
                      "the helper is not executable")
    }

    /// `Sources/SMC` is listed as a source path on two targets. If it ever ends up swept the way
    /// `Sources/Sarvkrit` is, the .swift files land in Contents/Resources — the same hazard the
    /// launch agent's tests already guard against for their own file.
    func testNoSwiftSourceWasCopiedIntoResources() throws {
        let resources = try appBundle().bundleURL.appendingPathComponent("Contents/Resources")
        let contents = try FileManager.default.contentsOfDirectory(atPath: resources.path)
        XCTAssertTrue(contents.filter { $0.hasSuffix(".swift") }.isEmpty,
                      "Swift sources were copied into Resources: \(contents)")
    }

    /// **The important one.** Runs the exact requirement string the root script embeds, against
    /// the exact binary it will run — so a signing change fails here, at `make test`, rather than
    /// after a password prompt in front of a user.
    func testTheHelperSatisfiesTheRequirementTheRootScriptDemands() throws {
        let url = try helperURL()

        var staticCode: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode), errSecSuccess)
        let code = try XCTUnwrap(staticCode)

        var requirement: SecRequirement?
        XCTAssertEqual(
            SecRequirementCreateWithString(
                FanHelperScript.codeRequirement as CFString, [], &requirement),
            errSecSuccess,
            "the requirement string does not parse: \(FanHelperScript.codeRequirement)")
        let parsed = try XCTUnwrap(requirement)

        let status = SecStaticCodeCheckValidity(code, [], parsed)
        XCTAssertEqual(status, errSecSuccess, """
            the shipped helper does not satisfy the root script's requirement (OSStatus \(status)).
            The script would exit 3 after the user typed their password.
            """)
    }
}
