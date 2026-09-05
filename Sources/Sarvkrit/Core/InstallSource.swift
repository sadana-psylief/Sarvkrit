import Foundation

/// How the running copy of Sarvkrit got onto this Mac.
///
/// This exists for exactly one reason: the update notice hands the user a command, and handing a
/// Homebrew user the `curl` command is actively harmful. The install script replaces
/// `/Applications/Sarvkrit.app` wholesale, which leaves Homebrew's receipt pointing at a version
/// that is no longer there — `brew upgrade` then has nothing to do, `brew uninstall` removes an
/// app it no longer recognises, and the two installers quietly fight over the same bundle.
enum InstallSource: Equatable {
    case homebrew
    case direct

    /// Homebrew Cask *moves* the real bundle to the applications directory and leaves a symlink
    /// behind in the Caskroom pointing back at it — the reverse of what you might expect, and the
    /// reason a brew-installed Sarvkrit keeps its Accessibility grant like any other copy.
    ///
    /// That symlink is the signal. Its path carries the version Homebrew believes is installed, so
    /// matching on the running bundle's own version is what stops a leftover Caskroom directory
    /// from an older release reading as "brew manages this". Both prefixes are checked because
    /// Homebrew lives at `/opt/homebrew` on Apple Silicon and `/usr/local` on Intel, and Sarvkrit
    /// ships universal.
    static func detect(
        bundleURL: URL = Bundle.main.bundleURL,
        version: String = Bundle.main.shortVersionString,
        prefixes: [String] = ["/opt/homebrew", "/usr/local"],
        fileManager: FileManager = .default
    ) -> InstallSource {
        let target = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        for prefix in prefixes {
            let link = URL(fileURLWithPath: prefix)
                .appendingPathComponent("Caskroom/sarvkrit")
                .appendingPathComponent(version)
                .appendingPathComponent("Sarvkrit.app")
            guard fileManager.fileExists(atPath: link.path) else { continue }
            if link.resolvingSymlinksInPath().standardizedFileURL == target { return .homebrew }
        }
        return .direct
    }

    /// What to tell the user to run to get the new version.
    ///
    /// The curl line is the default rather than the fallback: until the DMG is notarized it is the
    /// only route that does not send people through System Settings → Privacy & Security on every
    /// single update. The cask avoids that wall too, by stripping the quarantine attribute itself.
    var updateCommand: String {
        switch self {
        case .homebrew: "brew upgrade --cask sarvkrit"
        case .direct: "curl -fsSL https://sarvkrit.com/install | sh"
        }
    }
}
