import AppKit
import Foundation
import os

/// The system-wide `SleepDisabled` flag — the only thing that keeps a Mac awake with the lid shut.
///
/// Unlike a power assertion this is a machine-level setting that survives our process, the user's
/// session, and a reboot. Both setting *and* clearing it need root, so the design spends the one
/// authorisation the user grants on a watchdog that can clean up after we're gone.
enum SleepDisableFlag {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "KeepAwake")

    /// Tag on the watchdog process so a later activation can replace it instead of stacking.
    static let watchdogTag = "sarvkrit-sleep-watchdog"

    // MARK: - Reading (no privileges)

    /// What the system currently reports. Nil when `pmset` doesn't list the key at all — which is
    /// not the same as "sleep is enabled".
    static func currentState() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do { try process.run() } catch {
            log.error("could not run pmset: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return KeepAwakeState.parseSleepDisabled(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Writing (one password prompt)

    /// The script run with administrator privileges when the user turns the option on.
    ///
    /// Built as a string so its exact shape is unit-testable — this is a root shell command, and
    /// "looks right" is not good enough.
    static func enableScript(pid: Int32, watchdogSeconds: Int) -> String {
        """
        pkill -f '\(watchdogTag)' 2>/dev/null
        /usr/bin/pmset -a disablesleep 1
        nohup /bin/sh -c '# \(watchdogTag)
        i=0
        while kill -0 \(pid) 2>/dev/null && [ $i -lt \(watchdogSeconds) ]; do sleep 5; i=$((i+5)); done
        /usr/bin/pmset -a disablesleep 0' >/dev/null 2>&1 &
        """
    }

    static func disableScript() -> String {
        """
        pkill -f '\(watchdogTag)' 2>/dev/null
        /usr/bin/pmset -a disablesleep 0
        """
    }

    /// Runs a script as root via the standard macOS authorisation dialog.
    ///
    /// No privileged helper and no cached authorisation: `SMJobBless` needs a Developer ID
    /// certificate this app doesn't have, and a half-installed helper is far nastier to debug than
    /// typing a password.
    @discardableResult
    static func runPrivileged(_ script: String) -> Bool {
        let source = "do shell script \"\(escaped(script))\" with administrator privileges"
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else { return false }
        appleScript.executeAndReturnError(&error)

        if let error {
            // -128 is the user cancelling the dialog, which is a normal outcome, not a failure.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -128 {
                log.error("privileged command failed: \(String(describing: error), privacy: .public)")
            }
            return false
        }
        return true
    }

    private static func escaped(_ script: String) -> String {
        script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
