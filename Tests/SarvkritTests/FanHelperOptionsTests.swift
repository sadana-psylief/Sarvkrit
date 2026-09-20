import XCTest
@testable import Sarvkrit

/// How the root helper reads its own arguments.
///
/// Worth its own tests because the helper is launched by a shell script built in another file, and
/// the two agreeing is not something either of them can check at runtime. A helper that
/// misunderstands `--owner-pid` is a helper that never notices the app is gone.
final class FanHelperOptionsTests: XCTestCase {

    private let full = ["--tag", "sarvkrit-fan-helper", "--socket", "/tmp/fan.sock",
                        "--owner-pid", "4242", "--owner-uid", "501"]

    func testTheUsualArgumentsParse() throws {
        let options = try XCTUnwrap(FanHelperOptions(arguments: full))
        XCTAssertEqual(options.socketPath, "/tmp/fan.sock")
        XCTAssertEqual(options.ownerPID, 4242)
        XCTAssertEqual(options.ownerUID, 501)
        XCTAssertFalse(options.releaseAndExit)
    }

    /// The exact string `FanHelperScript` builds must parse. If these two ever drift, the feature
    /// fails after a password prompt, which is the most expensive place to find out.
    func testTheScriptThisProjectBuildsIsUnderstoodByTheHelper() throws {
        let script = try XCTUnwrap(FanHelperScript.launchScript(
            helperPath: "/Applications/Sarvkrit.app/Contents/MacOS/sarvkrit-fan-helper",
            socketPath: "/tmp/fan.sock", pid: 4242, uid: 501))
        let launchLine = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("--owner-pid") })

        // Everything after the staged binary, unquoted the way a shell would.
        let arguments = launchLine
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .drop { $0 != "--tag" }
            .prefix { $0 != ">/dev/null" }

        let options = try XCTUnwrap(FanHelperOptions(arguments: Array(arguments)))
        XCTAssertEqual(options.ownerPID, 4242)
        XCTAssertEqual(options.ownerUID, 501)
        XCTAssertEqual(options.socketPath, "/tmp/fan.sock")
    }

    func testTheOneShotReleaseNeedsNothingElse() throws {
        let options = try XCTUnwrap(FanHelperOptions(arguments: ["--release-and-exit"]))
        XCTAssertTrue(options.releaseAndExit)
    }

    /// Without a socket and an owner there is nothing to listen to and nobody to outlive, so the
    /// helper must refuse to start rather than sit there as a root process with no way out.
    func testAHelperWithNoOwnerRefusesToStart() {
        XCTAssertNil(FanHelperOptions(arguments: ["--socket", "/tmp/fan.sock"]))
        XCTAssertNil(FanHelperOptions(arguments: ["--owner-pid", "4242", "--owner-uid", "501"]))
        XCTAssertNil(FanHelperOptions(arguments: []))
    }

    func testAMalformedOwnerIsRefused() {
        XCTAssertNil(FanHelperOptions(arguments:
            ["--socket", "/tmp/f.sock", "--owner-pid", "nope", "--owner-uid", "501"]))
        XCTAssertNil(FanHelperOptions(arguments:
            ["--socket", "/tmp/f.sock", "--owner-pid", "0", "--owner-uid", "501"]))
    }

    /// Running as root on behalf of root is not a thing this feature does, and it is what an
    /// attacker would ask for.
    func testAHelperWillNotWorkOnBehalfOfRoot() {
        XCTAssertNil(FanHelperOptions(arguments:
            ["--socket", "/tmp/f.sock", "--owner-pid", "4242", "--owner-uid", "0"]))
    }

    /// The helper re-execs itself into its own session to escape the process group that
    /// `do shell script with administrator privileges` tears down. The second copy is told not to
    /// do it again, or it would spawn itself forever.
    func testTheDetachedFlagIsParsedAndDefaultsToFalse() throws {
        XCTAssertFalse(try XCTUnwrap(FanHelperOptions(arguments: full)).hasDetached)
        XCTAssertTrue(try XCTUnwrap(FanHelperOptions(arguments: full + ["--detached"])).hasDetached)
    }

    /// It is a bare flag, not a flag with a value — the parser must not swallow the next argument.
    func testTheDetachedFlagDoesNotSwallowWhatFollowsIt() throws {
        let options = try XCTUnwrap(FanHelperOptions(
            arguments: ["--detached", "--socket", "/tmp/f.sock",
                        "--owner-pid", "4242", "--owner-uid", "501"]))
        XCTAssertTrue(options.hasDetached)
        XCTAssertEqual(options.socketPath, "/tmp/f.sock")
        XCTAssertEqual(options.ownerPID, 4242)
    }

    func testTheIdleTimeoutHasASaneDefaultAndCanBeSet() throws {
        XCTAssertEqual(try XCTUnwrap(FanHelperOptions(arguments: full)).idleTimeout, 15)
        let custom = try XCTUnwrap(FanHelperOptions(arguments: full + ["--idle-timeout", "30"]))
        XCTAssertEqual(custom.idleTimeout, 30)
    }
}
