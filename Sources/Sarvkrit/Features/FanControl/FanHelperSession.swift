import Darwin
import Foundation
import os

/// Somewhere to send fan commands.
///
/// A protocol so the feature's decisions — the ceiling, the ramp, the fallback when the password
/// dialog is cancelled — can be tested without a root process on the other end. The real
/// implementation is `FanHelperSession`; the tests use a spy.
protocol FanCommandSink: AnyObject {
    var isConnected: Bool { get }
    /// Called when the helper goes away on its own. Never a cue to restart it.
    var onLost: (() -> Void)? { get set }

    /// Spends the password and waits for the helper to say hello. False if the user cancelled.
    func start() -> Bool
    func send(_ command: FanWire.Command)
    /// Hands the fans back and closes. Costs nothing — the helper is already root.
    func stop()
}

/// The app's end of the conversation with the root fan helper.
///
/// **Sarvkrit listens and the helper connects out.** The reverse would put an `accept` loop inside
/// the root process and make it responsible for filtering everyone who can reach it. This way the
/// privileged process opens one outbound connection and never listens at all, and each side
/// checks the other: the helper confirms the socket belongs to the user it works for, and this
/// confirms the peer is uid 0.
final class FanHelperSession: FanCommandSink {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "FanControl")

    var onLost: (() -> Void)?
    private(set) var isConnected = false

    private let runPrivileged: (String) -> Bool
    private let socketPath: String
    private var listener: Int32 = -1
    private var peer: Int32 = -1
    private var heartbeat: Timer?
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).fan-helper")

    init(socketPath: String, runPrivileged: @escaping (String) -> Bool) {
        self.socketPath = socketPath
        self.runPrivileged = runPrivileged
    }

    deinit { stop() }

    /// Where the socket lives. Inside the app's own Application Support directory, which is
    /// already the user's and already private.
    static func defaultSocketPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Sarvkrit", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("fan.sock").path
    }

    func start() -> Bool {
        guard !isConnected else { return true }
        guard bind() else { return false }

        guard let helperPath = Bundle.main.bundleURL
            .appendingPathComponent(FanHelperScript.bundledPath).path as String?,
            let script = FanHelperScript.launchScript(
                helperPath: helperPath, socketPath: socketPath,
                pid: ProcessInfo.processInfo.processIdentifier, uid: getuid())
        else {
            closeEverything()
            return false
        }

        // The password dialog. `false` here is usually the user cancelling, which is an ordinary
        // outcome and not a failure to report.
        guard runPrivileged(script) else {
            closeEverything()
            return false
        }

        guard acceptHelper() else {
            closeEverything()
            return false
        }

        isConnected = true
        startHeartbeat()
        watchForLoss()
        return true
    }

    func send(_ command: FanWire.Command) {
        guard isConnected, peer >= 0 else { return }
        let line = FanWire.encode(command)
        _ = line.withCString { Darwin.write(peer, $0, strlen($0)) }
    }

    func stop() {
        guard isConnected || listener >= 0 else { return }
        if isConnected {
            // Hand the fans back before closing, rather than relying on the helper noticing.
            send(.auto)
            send(.quit)
        }
        closeEverything()
    }

    // MARK: - Sockets

    private func bind() -> Bool {
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return false }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            closeEverything()
            return false
        }
        // Ours alone. The helper checks this from its side too.
        chmod(socketPath, 0o600)
        return true
    }

    /// Waits a short while for the helper to appear, then gives up.
    ///
    /// **`poll()` before `accept()`, not `SO_RCVTIMEO`.** That socket option bounds data reads,
    /// not connection acceptance — an `accept()` on a listener nobody ever connects to blocks
    /// forever regardless of it. This runs on the main thread, where the event tap's run loop
    /// lives, so "forever" would be felt as input latency in whatever app the user is typing in.
    /// A helper that never arrives is an ordinary outcome: the copy failed, the signature check
    /// failed, the SMC would not open.
    private func acceptHelper() -> Bool {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 10_000)
        guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else {
            Self.log.error("the fan helper never connected")
            return false
        }

        peer = accept(listener, nil, nil)
        guard peer >= 0 else { return false }

        // The only acceptable peer is root. Anything else is not our helper, whatever it says.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(peer, &peerUID, &peerGID) == 0, peerUID == 0 else {
            Self.log.error("refusing a fan helper connection from uid \(peerUID, privacy: .public)")
            return false
        }
        return true
    }

    private func startHeartbeat() {
        // Comfortably inside the helper's idle timeout, so an ordinary quiet spell never looks
        // like the app having died.
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.send(.ping) }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    /// Notices the helper closing its end. Reading is the only way to find out, and it must not
    /// happen on the main thread.
    private func watchForLoss() {
        let descriptor = peer
        queue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { continue }
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                break
            }
            DispatchQueue.main.async {
                guard let self, self.isConnected, self.peer == descriptor else { return }
                self.closeEverything()
                self.onLost?()
            }
        }
    }

    private func closeEverything() {
        heartbeat?.invalidate()
        heartbeat = nil
        if peer >= 0 { close(peer); peer = -1 }
        if listener >= 0 { close(listener); listener = -1 }
        unlink(socketPath)
        isConnected = false
    }
}
