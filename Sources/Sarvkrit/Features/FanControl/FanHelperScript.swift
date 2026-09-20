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

    /// Pins the anchor, the helper's identity and the team, and deliberately not the certificate's
    /// common name — that carries the personal name on an Apple Development certificate and
    /// changes when the certificate is reissued.
    static let codeRequirement =
        "identifier \"\(bundleIdentifier)\" and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"77A36893HP\""

    /// One password, one long-lived root process listening on `socketPath`.
    static func launchScript(helperPath: String, socketPath: String, pid: Int32, uid: uid_t)
        -> String? {
        guard let helper = shellQuoted(helperPath), let socket = shellQuoted(socketPath) else {
            return nil
        }
        let run = "/usr/bin/nohup \"$STAGE/helper\" --tag '\(tag)' --socket \(socket)"
            + " --owner-pid \(pid) --owner-uid \(uid) >/dev/null 2>&1 &"
        return preamble(helper: helper) + "\n" + run
    }

    /// A one-shot for the stranded case: hand the fans back and exit. No socket, no `nohup`, and
    /// nothing left running — a release that left a root process behind would be the opposite of
    /// what was asked for.
    static func releaseScript(helperPath: String) -> String? {
        guard let helper = shellQuoted(helperPath) else { return nil }
        return """
        \(preamble(helper: helper))
        "$STAGE/helper" --release-and-exit
        /bin/rm -rf "$STAGE"
        """
    }

    private static func preamble(helper: String) -> String {
        let verify = "/usr/bin/codesign --verify --strict -R='\(codeRequirement)' \"$STAGE/helper\""
        return """
        pkill -f '\(tag)' 2>/dev/null
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
