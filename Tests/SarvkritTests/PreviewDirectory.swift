import Foundation

/// Where the snapshot suites write their PNGs, or nil when previews are off.
///
/// **Empty counts as off, and that is the whole reason this exists.** The scheme forwards
/// `SARVKRIT_PREVIEW_DIR` into the test host as a build setting, because xcodebuild does not hand
/// the test host its own environment and without the forwarding every writer in this target was
/// dead code that skipped silently. But a forwarded setting that nobody set arrives *present and
/// empty* rather than absent — so a bare `guard let` on the environment succeeds, hands the writer
/// `""`, and it tries to save `/canvas-plain.png` to the read-only root volume. Which it did, in
/// eleven suites at once.
///
/// Also creates the directory: a path that has to exist before the run is a path people get wrong.
enum PreviewDirectory {
    static var path: String? {
        guard let path = ProcessInfo.processInfo.environment["SARVKRIT_PREVIEW_DIR"],
              !path.isEmpty else { return nil }
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
