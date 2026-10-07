import Darwin
import XCTest
@testable import Sarvkrit

/// `FanHelperSession` against a real helper process on a real socket.
///
/// The helper here runs as the ordinary user rather than root, which is the whole point: it proves
/// the app refuses a connection from anything that is not root. Nothing else in the suite covers
/// the accept path, and this one found a bug the unit tests structurally could not — every other
/// test replaces the session with a spy.
final class FanHelperSessionTests: XCTestCase {

    private func bundledHelper() throws -> String {
        let path = Bundle.main.bundleURL
            .appendingPathComponent(FanHelperScript.bundledPath).path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: path),
                          "not hosted in a built Sarvkrit.app")
        // The helper opens the SMC before it connects and exits 70 if it cannot, so on a Mac
        // without one (CI's virtualized runners) it never reaches anything these tests look at.
        // The refusal tests would still pass there, but only because nothing connected at all.
        try XCTSkipUnless(SMCClient().open(),
                          "no AppleSMC user client here, so the helper exits before connecting")
        return path
    }

    /// Launches the real helper as *this* user, skipping the privileged staging the root script
    /// does. Everything else — the socket, the connect, the handshake — is real.
    private func session(socket: String, helper: String) -> FanHelperSession {
        FanHelperSession(socketPath: socket) { _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c",
                "/usr/bin/nohup '\(helper)' --tag 'sarvkrit-fan-helper' --socket '\(socket)' "
                + "--owner-pid \(getpid()) --owner-uid \(getuid()) >/dev/null 2>&1 &"]
            try? process.run()
            process.waitUntilExit()
            return true
        }
    }

    /// The privilege boundary, tested rather than asserted in a comment. A helper that is not root
    /// is not our helper, whatever it claims — and since the app is the listener, anything running
    /// as this user can reach that socket and try.
    func testAHelperThatIsNotRootIsRefused() throws {
        let helper = try bundledHelper()
        let socket = "/tmp/sarvkrit-fan-test-\(getpid()).sock"
        defer { unlink(socket) }

        let session = self.session(socket: socket, helper: helper)
        XCTAssertFalse(session.start(), "a connection from a non-root peer must be refused")
        XCTAssertFalse(session.isConnected)
        session.stop()
    }

    /// A refused session must leave nothing behind — no listening socket, no file in the way of
    /// the next attempt.
    func testARefusedSessionCleansUpItsSocket() throws {
        let helper = try bundledHelper()
        let socket = "/tmp/sarvkrit-fan-test-clean-\(getpid()).sock"
        defer { unlink(socket) }

        _ = self.session(socket: socket, helper: helper).start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket),
                       "the socket was left behind")
    }

    /// The path the app actually uses has to fit what a unix socket allows — 104 bytes on macOS,
    /// including the terminator. A longer one fails at bind with no obvious symptom.
    func testTheDefaultSocketPathFitsWhatAUnixSocketAllows() {
        XCTAssertLessThan(FanHelperSession.defaultSocketPath().utf8.count, 100)
    }
}
