import Foundation

/// The script Sarvkrit runs as root to start, or stop, the fan helper.
///
/// Built as a string so its exact shape is unit-testable, exactly as `SleepDisableFlag` does it.
/// This is a root shell command; "looks right" is not good enough.
///
/// **The escalation surface, stated plainly.** `/Applications/Sarvkrit.app` is owned by whoever
/// installed it, so a process running as that user can replace the helper binary inside it. Left
/// alone, that turns one password prompt into root. Two things narrow it:
///
/// 1. The script copies the helper into a root-owned directory, verifies *that copy*, and runs
///    *that copy*. Verifying the binary where it sits would leave a window between the check and
///    the launch in which it could be swapped.
/// 2. The requirement pins the helper's own identifier as well as the team. The team alone is
///    satisfied by every binary this team ever signs — Sarvkrit itself included — so an attacker
///    who could redirect the path would otherwise get the main app run as root.
///
/// It is a mitigation and not a cure: anyone who can already write into the app bundle has other
/// routes. It closes the trivial swap, and the README says so beside the Keep Awake paragraph
/// that set the precedent for spending a password at all.
enum FanHelperScript {
    /// Lands in the helper's argv so a later activation can replace it rather than stack beside
    /// it. `SleepDisableFlag.watchdogTag`'s trick.
    static let tag = "sarvkrit-fan-helper"

    static let bundleIdentifier = "ai.psylief.sarvkrit.fanhelper"

    /// Where the helper sits inside the app bundle, relative to the `.app` itself.
    /// `FanHelperBundleTests` asserts the build actually puts it here.
    static let bundledPath = "Contents/MacOS/sarvkrit-fan-helper"

    /// Pins the anchor, the helper's identity and the team, and deliberately not the certificate's
    /// common name — that carries the personal name on an Apple Development certificate and
    /// changes when the certificate is reissued.
    static let codeRequirement =
        "identifier \"\(bundleIdentifier)\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"77A36893HP\""

    /// The launchd job the helper runs as. One label, so a second activation replaces the first.
    static let jobLabel = "ai.psylief.sarvkrit.fanhelper"

    /// One password, one long-lived root process connecting to `socketPath`.
    ///
    /// **The helper is handed to launchd rather than backgrounded.** `do shell script ... with
    /// administrator privileges` reaps everything the script started the moment it returns, and
    /// neither `nohup &` nor a `setsid()` re-exec escapes it. Both were shipped and both were
    /// measured dying within 100 ms, without logging a line. A job bootstrapped into the system
    /// domain belongs to launchd, not to the script, so it outlives it. `KeepAlive` is false, so
    /// when the helper exits on any of its own ways out, launchd leaves it exited.
    ///
    /// The plist lives in the root-owned stage directory and is never installed anywhere that
    /// persists, so a reboot leaves nothing behind.
    static func launchScript(helperPath: String, socketPath: String, pid: Int32, uid: uid_t)
        -> String? {
        guard let helper = shellQuoted(helperPath), shellQuoted(socketPath) != nil else {
            return nil
        }
        // The helper's own path is set afterwards with PlistBuddy, because the plist is written
        // through a quoted heredoc that expands nothing, so `$STAGE` cannot appear in it.
        let arguments = [stagedPlaceholder, "--tag", tag, "--socket", socketPath,
                         "--owner-pid", String(pid), "--owner-uid", String(uid)]
        return """
        \(preamble(helper: helper))
        /bin/cat > "$STAGE/job.plist" <<'PLIST'
        \(jobPlist(arguments: arguments))
        PLIST
        /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $STAGE/helper" "$STAGE/job.plist" || exit 4
        /bin/chmod 0644 "$STAGE/job.plist" || exit 4
        /bin/launchctl bootstrap system "$STAGE/job.plist" || exit 5
        """
    }

    /// Stands in for the staged helper's path until PlistBuddy replaces it.
    static let stagedPlaceholder = "STAGED_HELPER"

    static func jobPlist(arguments: [String]) -> String {
        let strings = arguments.map { "<string>\(xmlEscaped($0))</string>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\
        <key>Label</key><string>\(jobLabel)</string>\
        <key>ProgramArguments</key><array>\(strings)</array>\
        <key>RunAtLoad</key><true/>\
        <key>KeepAlive</key><false/>\
        </dict></plist>
        """
    }

    private static func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A one-shot for the stranded case: hand the fans back and exit. No socket, no job, and
    /// nothing left running. A release that left a root process behind would be the opposite of
    /// what was asked for. It runs in the foreground, so it finishes before the script returns.
    static func releaseScript(helperPath: String) -> String? {
        guard let helper = shellQuoted(helperPath) else { return nil }
        return """
        \(preamble(helper: helper))
        "$STAGE/helper" --release-and-exit
        /bin/rm -rf "$STAGE"
        """
    }

    /// Stops whatever is already running before staging a new copy: the launchd job, and any
    /// helper a pre-launchd build left behind. Booting the job out sends it SIGTERM, which the
    /// helper answers by handing the fans back. Earlier stage directories go with it.
    private static func preamble(helper: String) -> String {
        let verify = "/usr/bin/codesign --verify --strict -R='\(codeRequirement)' \"$STAGE/helper\""
        return """
        /bin/launchctl bootout system/\(jobLabel) 2>/dev/null
        /usr/bin/pkill -f '\(tag)' 2>/dev/null
        /bin/rm -rf /var/run/sarvkrit-fan.*
        STAGE=$(/usr/bin/mktemp -d /var/run/sarvkrit-fan.XXXXXXXX) || exit 2
        /usr/sbin/chown root:wheel "$STAGE" || exit 2
        /bin/chmod 0700 "$STAGE" || exit 2
        /bin/cp \(helper) "$STAGE/helper" || exit 2
        /usr/sbin/chown root:wheel "$STAGE/helper" || exit 2
        /bin/chmod 0500 "$STAGE/helper" || exit 2
        \(verify) || { /bin/rm -rf "$STAGE"; exit 3; }
        """
    }

    /// Single-quotes a path, closing and reopening the quote around any single quote inside it —
    /// the only construct that can escape a single-quoted shell string.
    ///
    /// Returns `nil` for a newline or a NUL rather than trying to quote them. No real bundle path
    /// contains either, and a newline cannot be made safe here cheaply enough to be worth the
    /// risk of being wrong. The user can rename the app to anything, so this is reachable input,
    /// not a hypothetical.
    static func shellQuoted(_ path: String) -> String? {
        guard !path.contains("\n"), !path.contains("\0"), !path.contains("\r") else { return nil }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
