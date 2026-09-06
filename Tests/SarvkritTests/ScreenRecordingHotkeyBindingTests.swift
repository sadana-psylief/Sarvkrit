import XCTest
@testable import Sarvkrit

/// When the recording shortcuts get bound, relative to when their closures exist.
///
/// **This suite exists because ⌃⇧R did nothing until the feature was switched off and on again.**
///
/// `AppState.shared`'s initialiser ends in `sync()`, and it is forced by `wireClipboardPicker()`
/// at the top of `applicationDidFinishLaunching`. `wireRecording()` — which assigns `startStop`
/// and its three siblings — runs four lines later. So `rebindHotkeys()` always runs with every
/// closure still nil, and it used to read them by value:
///
/// ```swift
/// case .startStop: return startStop        // nil, so `guard let handler … else { continue }`
/// ```
///
/// Zero shortcuts were registered, and nothing ever registered them afterwards: `sync()` only
/// activates features not already in `activeFeatureIDs`, so the single escape was to leave that
/// set — which is exactly what toggling the feature off and on does.
///
/// `ScreenshotFeature` has the identical launch ordering and works, because its handlers read the
/// property at fire time instead. Its own comment states the contract: *"Nil until then, and every
/// call site tolerates that — a nil closure is how a not-yet-built half of the feature is absent
/// rather than crashing."*
final class ScreenRecordingHotkeyBindingTests: XCTestCase {

    private func makeFeature() -> ScreenRecordingFeature {
        ScreenRecordingFeature(defaults: UserDefaults(suiteName: "recording.\(UUID())")!)
    }

    /// The bug, stated directly: at the moment `rebindHotkeys()` runs, every action must still
    /// have something to register.
    func testEveryActionHasAHandlerBeforeItsClosureIsAssigned() {
        let feature = makeFeature()

        for action in RecordingAction.allCases {
            XCTAssertNotNil(feature.handler(for: action),
                            "\(action.rawValue) has no handler before AppDelegate wires it up, "
                            + "so rebindHotkeys() skips it and the shortcut is never registered")
        }
    }

    /// And the handler taken at registration time has to see a closure assigned afterwards —
    /// which is the whole point of late binding, and the half a nil check would not catch.
    func testAHandlerTakenBeforeAssignmentStillReachesTheClosure() {
        let feature = makeFeature()
        // Taken first, exactly as `rebindHotkeys()` does at launch.
        let handlers = RecordingAction.allCases.map { ($0, feature.handler(for: $0)) }

        var fired: Set<String> = []
        feature.startStop = { fired.insert("startStop") }
        feature.recordArea = { fired.insert("recordArea") }
        feature.pauseResume = { fired.insert("pauseResume") }
        feature.markMoment = { fired.insert("markMoment") }

        for (_, handler) in handlers { handler?() }

        XCTAssertEqual(fired, ["startStop", "recordArea", "pauseResume", "markMoment"])
    }

    /// A handler fired while its closure is still nil must do nothing rather than crash — the
    /// window between registration and wiring is real, if short.
    func testAHandlerFiredBeforeAssignmentDoesNothing() {
        let feature = makeFeature()
        for action in RecordingAction.allCases {
            feature.handler(for: action)?()
        }
    }
}
