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

    /// The bug that made this feature do nothing at all.
    ///
    /// `do shell script ... with administrator privileges` runs through Authorization Services and
    /// **kills the whole process group when it returns** — `nohup` and `&` do not save a child
    /// from that, because it is not being hung up, it is being killed. The helper has to put
    /// itself in a session of its own before that cleanup runs.
    ///
    /// Observable consequence, and what this asserts: after `setsid()` the helper leads its own
    /// process group, so its pgid equals its pid. Without it the helper stays in the group of the
    /// shell that launched it — the group that gets torn down.
    ///
    /// Deliberately **not** asserted by parent pid: a backgrounded process whose shell exits is
    /// re-parented to launchd either way, so `ppid == 1` holds with or without the fix and would
    /// be a test that cannot fail.
    func testTheHelperDetachesFromTheProcessGroupThatLaunchedIt() throws {
        let helper = try bundledHelper()
        let socket = "/tmp/sarvkrit-fan-detach-\(getpid()).sock"
        defer { unlink(socket) }

        // A listener that never accepts, so the helper stays up long enough to be inspected.
        let listener = socket_bindOnly(socket)
        defer { if listener >= 0 { close(listener) } }
        try XCTSkipUnless(listener >= 0, "could not bind a test socket")

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c",
            "'\(helper)' --tag 'sarvkrit-detach-test' --socket '\(socket)' "
            + "--owner-pid \(getpid()) --owner-uid \(getuid()) >/dev/null 2>&1 &"]
        try shell.run()
        shell.waitUntilExit()

        // Give it a moment to fork, setsid and connect.
        Thread.sleep(forTimeInterval: 1.5)

        let found = Process()
        found.executableURL = URL(fileURLWithPath: "/bin/ps")
        found.arguments = ["-Ao", "pid=,pgid=,command="]
        let pipe = Pipe()
        found.standardOutput = pipe
        try found.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        found.waitUntilExit()

        let row = listing.split(separator: "\n").first { $0.contains("sarvkrit-detach-test") }
        let helperRow = try XCTUnwrap(row, "the helper is not running at all")
        let columns = helperRow.split(separator: " ", omittingEmptySubsequences: true)
        let pid = Int(columns[0]) ?? -1
        let group = Int(columns[1]) ?? -2

        // Clean up before asserting, so a failure does not leave a fan helper running.
        if pid > 0 { kill(pid_t(pid), SIGTERM) }

        XCTAssertEqual(group, pid,
                       "the helper is still in the launching shell's process group, so the "
                       + "cleanup after an administrator do-shell-script would kill it")
    }

    /// Binds and listens without ever accepting.
    private func socket_bindOnly(_ path: String) -> Int32 {
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { close(descriptor); return -1 }
        return descriptor
    }

    /// The path the app actually uses has to fit what a unix socket allows — 104 bytes on macOS,
    /// including the terminator. A longer one fails at bind with no obvious symptom.
    func testTheDefaultSocketPathFitsWhatAUnixSocketAllows() {
        XCTAssertLessThan(FanHelperSession.defaultSocketPath().utf8.count, 100)
    }
}
