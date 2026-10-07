import XCTest
@testable import Sarvkrit

/// The script that runs as root.
///
/// Asserted as exact text, the way `SleepDisableFlagTests` asserts the `pmset` scripts, for the
/// same reason: this is a root shell command and "looks right" is not good enough.
final class FanHelperScriptTests: XCTestCase {
    private let helper = "/Applications/Sarvkrit.app/Contents/MacOS/sarvkrit-fan-helper"
    private let socket = "/Users/someone/Library/Application Support/Sarvkrit/fan.sock"

    private func launch(helperPath: String? = nil, socketPath: String? = nil) -> String? {
        FanHelperScript.launchScript(
            helperPath: helperPath ?? helper, socketPath: socketPath ?? socket,
            pid: 4242, uid: 501)
    }

    /// The launchd job the script would bootstrap, parsed the way launchd parses it.
    private func job(socketPath: String? = nil) throws -> [String: Any] {
        let script = try XCTUnwrap(launch(socketPath: socketPath))
        let start = try XCTUnwrap(script.range(of: "<?xml"))
        let plist = script[start.lowerBound...].components(separatedBy: "\nPLIST")[0]
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(plist.utf8), format: nil) as? [String: Any])
    }

    private func arguments(socketPath: String? = nil) throws -> [String] {
        try XCTUnwrap(job(socketPath: socketPath)["ProgramArguments"] as? [String])
    }

    // MARK: - The signing requirement

    /// The team OU alone is satisfied by *every* binary this team ever signs — including Sarvkrit
    /// itself. Pointing the script at the main app executable would otherwise pass this check and
    /// get it run as root. The identifier alone is no better: it admits an ad-hoc binary claiming
    /// the same name. Both together is the check.
    func testTheRequirementPinsTheIdentifierAsWellAsTheTeam() {
        let requirement = FanHelperScript.codeRequirement
        XCTAssertTrue(requirement.contains("identifier \"ai.psylief.sarvkrit.fanhelper\""),
                      "requirement must pin the helper's identifier: \(requirement)")
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"77A36893HP\""),
                      "requirement must pin the team: \(requirement)")
        XCTAssertTrue(requirement.contains("anchor apple generic"),
                      "requirement must pin the anchor: \(requirement)")
    }

    /// The certificate's common name carries the personal name on an Apple Development cert and
    /// changes when the cert is reissued. Pinning it would break the feature on cert rotation.
    func testTheRequirementDoesNotPinTheCertificateCommonName() {
        XCTAssertFalse(FanHelperScript.codeRequirement.contains("subject.CN"))
    }

    // MARK: - Copy, verify the copy, run the copy

    /// The app bundle is owned by whoever installed it, so a process running as that user can
    /// swap the helper between the check and the launch. Verifying a root-owned copy closes the
    /// window: what was read is what is verified and what is run.
    func testTheScriptStagesTheHelperBeforeVerifyingIt() throws {
        let script = try XCTUnwrap(launch())
        let copy = try XCTUnwrap(script.range(of: "/bin/cp"))
        let verify = try XCTUnwrap(script.range(of: "/usr/bin/codesign"))
        XCTAssertLessThan(copy.lowerBound, verify.lowerBound,
                          "the helper must be copied before it is verified")
    }

    func testTheScriptVerifiesTheHelperBeforeRunningIt() throws {
        let script = try XCTUnwrap(launch())
        let verify = try XCTUnwrap(script.range(of: "/usr/bin/codesign"))
        let run = try XCTUnwrap(script.range(of: "/bin/launchctl bootstrap"))
        XCTAssertLessThan(verify.lowerBound, run.lowerBound,
                          "the helper must be verified before it is run")
    }

    /// The staged copy is what runs. Running the original would make the verification decorative.
    func testTheScriptRunsTheStagedCopyRatherThanTheBundledBinary() throws {
        let script = try XCTUnwrap(launch())
        XCTAssertEqual(try arguments().first, FanHelperScript.stagedPlaceholder)
        XCTAssertTrue(script.contains(
            "/usr/libexec/PlistBuddy -c \"Set :ProgramArguments:0 $STAGE/helper\""))
        let mentions = script.components(separatedBy: helper).count - 1
        XCTAssertEqual(mentions, 1, "the bundled path should appear only in the copy")
    }

    func testTheStagingDirectoryIsRootOwnedAndPrivate() throws {
        let script = try XCTUnwrap(launch())
        XCTAssertTrue(script.contains("/usr/bin/mktemp -d"))
        XCTAssertTrue(script.contains("/bin/chmod 0700"))
        XCTAssertTrue(script.contains("/usr/sbin/chown root:wheel"))
    }

    // MARK: - Shape

    /// A relative path would resolve against whatever PATH root happens to have.
    func testEveryBinaryIsCalledByAbsolutePath() throws {
        let script = try XCTUnwrap(launch())
        for tool in ["cp", "chmod", "chown", "mktemp", "codesign", "pkill", "launchctl",
                     "PlistBuddy", "rm", "cat"] {
            XCTAssertFalse(script.contains(" \(tool) "), "\(tool) is called without a full path")
        }
    }

    /// A second activation must replace the previous helper, not stack another root process
    /// beside it. The same tag trick `SleepDisableFlag` uses.
    func testAPreviousHelperIsKilledFirst() throws {
        let script = try XCTUnwrap(launch())
        XCTAssertTrue(script.contains("pkill -f '\(FanHelperScript.tag)'"))
        XCTAssertTrue(script.contains("/bin/launchctl bootout system/\(FanHelperScript.jobLabel)"))
        let copy = try XCTUnwrap(script.range(of: "/bin/cp"))
        for step in ["/bin/launchctl bootout", "pkill"] {
            let range = try XCTUnwrap(script.range(of: step))
            XCTAssertLessThan(range.lowerBound, copy.lowerBound, "\(step) must come first")
        }
    }

    func testTheHelperIsToldWhoItIsWorkingFor() throws {
        XCTAssertEqual(try arguments().dropFirst(), [
            "--tag", FanHelperScript.tag, "--socket", socket,
            "--owner-pid", "4242", "--owner-uid", "501"])
    }

    // MARK: - Launched by launchd, not by the script

    /// `do shell script ... with administrator privileges` reaps everything the script started
    /// when it returns. `nohup &` and a `setsid()` re-exec were both measured dying within 100 ms.
    /// A system-domain job belongs to launchd, so it survives the script.
    func testTheHelperIsBootstrappedAsALaunchdJobRatherThanBackgrounded() throws {
        let script = try XCTUnwrap(launch())
        XCTAssertTrue(script.hasSuffix(#"/bin/launchctl bootstrap system "$STAGE/job.plist" || exit 5"#))
        XCTAssertFalse(script.contains("nohup"))
        XCTAssertFalse(script.contains(" &\n") || script.hasSuffix("&"), "nothing is backgrounded")
        XCTAssertEqual(try job()["Label"] as? String, FanHelperScript.jobLabel)
    }

    /// The helper's ways out (app gone, socket closed, idle, signal) all end in exit. launchd must
    /// let that stand rather than starting a fresh root process nobody asked for.
    func testLaunchdDoesNotRestartTheHelperWhenItExits() throws {
        XCTAssertEqual(try job()["KeepAlive"] as? Bool, false)
        XCTAssertEqual(try job()["RunAtLoad"] as? Bool, true)
    }

    /// The plist goes through a quoted heredoc, so the shell expands nothing in it, and the socket
    /// path is XML-escaped. Both have to hold for the path to reach the helper intact.
    func testAnAwkwardSocketPathReachesTheHelperIntact() throws {
        let awkward = "/Users/a&b <c>/$(whoami)/`id`/fan.sock"
        XCTAssertEqual(try arguments(socketPath: awkward)[4], awkward)
        XCTAssertTrue(try XCTUnwrap(launch(socketPath: awkward)).contains("<<'PLIST'"))
    }

    // MARK: - Quoting, because the user can rename the app

    func testAPathContainingASpaceIsQuoted() throws {
        let script = try XCTUnwrap(launch(helperPath: "/Applications/My Fans.app/helper"))
        XCTAssertTrue(script.contains("'/Applications/My Fans.app/helper'"))
    }

    /// The one that breaks naive quoting: a single quote closes the string the path sits in.
    func testAPathContainingASingleQuoteCannotBreakOutOfTheString() throws {
        let script = try XCTUnwrap(launch(helperPath: "/Applications/Tim's.app/helper"))
        XCTAssertTrue(script.contains("'/Applications/Tim'\\''s.app/helper'"),
                      "single quote is not escaped: \(script)")
    }

    func testAPathContainingAShellExpansionIsNotExpanded() throws {
        let script = try XCTUnwrap(launch(helperPath: "/Applications/$(whoami).app/helper"))
        XCTAssertTrue(script.contains("'/Applications/$(whoami).app/helper'"))
    }

    /// A newline cannot be quoted into a single-quoted string safely enough to be worth trying,
    /// and no real bundle path contains one. Refuse to build the script at all.
    func testAPathContainingANewlineIsRefusedOutright() {
        XCTAssertNil(launch(helperPath: "/Applications/evil\nrm -rf.app/helper"))
        XCTAssertNil(launch(socketPath: "/tmp/evil\nsock"))
    }

    // MARK: - Letting go

    func testTheReleaseScriptVerifiesTheHelperTheSameWay() throws {
        let script = try XCTUnwrap(FanHelperScript.releaseScript(helperPath: helper))
        XCTAssertTrue(script.contains("/usr/bin/codesign"))
        XCTAssertTrue(script.contains("--release-and-exit"))
        let verify = try XCTUnwrap(script.range(of: "/usr/bin/codesign"))
        let run = try XCTUnwrap(script.range(of: "--release-and-exit"))
        XCTAssertLessThan(verify.lowerBound, run.lowerBound)
    }

    /// Letting go is a one-shot. A release that left a root process listening would be the
    /// opposite of what the user asked for.
    func testTheReleaseScriptDoesNotLeaveAHelperRunning() throws {
        let script = try XCTUnwrap(FanHelperScript.releaseScript(helperPath: helper))
        XCTAssertFalse(script.contains("--owner-pid"))
        XCTAssertFalse(script.contains("nohup"))
    }
}
