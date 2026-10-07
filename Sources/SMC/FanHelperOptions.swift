import Foundation

/// The root helper's arguments.
///
/// Lives in the shared SMC layer rather than beside the helper's `main.swift` so that it can be
/// tested from the app's suite — including against the exact command line `FanHelperScript`
/// builds. The script and the helper agreeing is not something either can check at runtime, and
/// a disagreement surfaces after a password prompt, which is the most expensive place to find one.
struct FanHelperOptions {
    var socketPath: String
    /// The app. When this process goes, the fans go back to macOS.
    var ownerPID: pid_t
    /// Who the socket belongs to, and the only uid allowed to be on the other end of it.
    var ownerUID: uid_t
    var idleTimeout: TimeInterval
    /// One-shot: hand the fans back and exit, for a hold left behind by a helper that died badly.
    var releaseAndExit: Bool

    init?(arguments: [String]) {
        var values: [String: String] = [:]
        var releaseAndExit = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--release-and-exit" {
                releaseAndExit = true
                index += 1
            } else if argument.hasPrefix("--"), index + 1 < arguments.count {
                values[argument] = arguments[index + 1]
                index += 2
            } else {
                return nil
            }
        }

        self.releaseAndExit = releaseAndExit
        self.idleTimeout = values["--idle-timeout"].flatMap(TimeInterval.init) ?? 15

        if releaseAndExit {
            // Nothing to outlive and nothing to listen to.
            self.socketPath = ""
            self.ownerPID = 0
            self.ownerUID = 0
            return
        }

        // A long-lived root process with no owner would have no way to know when to stop, so the
        // three that give it one are all required.
        guard let socketPath = values["--socket"],
              let pid = values["--owner-pid"].flatMap(pid_t.init), pid > 0,
              let uid = values["--owner-uid"].flatMap(uid_t.init), uid > 0
        else { return nil }

        self.socketPath = socketPath
        self.ownerPID = pid
        self.ownerUID = uid
    }
}
