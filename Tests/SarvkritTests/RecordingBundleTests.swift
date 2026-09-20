import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The `.sarvrec` bundle: what is written while recording, and what survives a crash.
///
/// A recording is hundreds of megabytes of somebody's afternoon. The manifest is written *before*
/// the first frame and says `recording`; a bundle still saying that on next launch is one the app
/// died in the middle of, and the only acceptable outcome is to keep what exists.
final class RecordingBundleTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvrec-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Layout

    func testCreatingABundleMakesItsDirectory() throws {
        let bundle = try RecordingBundle.create(at: root)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.root.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testEveryPieceLivesInsideTheBundle() throws {
        let bundle = try RecordingBundle.create(at: root)
        for url in [bundle.screenURL, bundle.eventsURL, bundle.manifestURL, bundle.cursorsDirectory] {
            XCTAssertTrue(url.path.hasPrefix(bundle.root.path), "\(url.lastPathComponent) escaped")
        }
    }

    func testTheScreenTrackIsAQuickTimeMovie() throws {
        XCTAssertEqual(try RecordingBundle.create(at: root).screenURL.pathExtension, "mov")
    }

    // MARK: - Manifest

    func testAManifestSurvivesARoundTrip() throws {
        let bundle = try RecordingBundle.create(at: root)
        var manifest = RecordingManifest(source: .area,
                                         pixelSize: CGSize(width: 1920, height: 1080),
                                         pointPixelScale: 2,
                                         fps: 60)
        manifest.duration = 12.5
        manifest.droppedFrames = 4
        try bundle.write(manifest)
        XCTAssertEqual(try bundle.readManifest(), manifest)
    }

    /// Written before the first frame, so a bundle found in this state was interrupted.
    func testAFreshManifestSaysItIsStillRecording() {
        let manifest = RecordingManifest(source: .display,
                                         pixelSize: CGSize(width: 100, height: 100),
                                         pointPixelScale: 1, fps: 60)
        XCTAssertEqual(manifest.state, .recording)
    }

    func testAManifestFromAnUnfinishedRecordingIsRecognised() throws {
        let bundle = try RecordingBundle.create(at: root)
        try bundle.write(RecordingManifest(source: .display,
                                           pixelSize: CGSize(width: 100, height: 100),
                                           pointPixelScale: 1, fps: 60))
        XCTAssertTrue(try bundle.readManifest().needsRecovery)
    }

    func testAFinishedRecordingDoesNotNeedRecovery() throws {
        let bundle = try RecordingBundle.create(at: root)
        var manifest = RecordingManifest(source: .display,
                                         pixelSize: CGSize(width: 100, height: 100),
                                         pointPixelScale: 1, fps: 60)
        manifest.state = .complete
        try bundle.write(manifest)
        XCTAssertFalse(try bundle.readManifest().needsRecovery)
    }

    /// A manifest written by a newer build must open. Same contract as the project document.
    func testAManifestMissingKeysDecodesToDefaults() throws {
        let json = #"{"source":"area","pixelSize":{"width":800,"height":600}}"#.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(RecordingManifest.self, from: json)
        XCTAssertEqual(manifest.source, .area)
        XCTAssertEqual(manifest.fps, RecordingManifest.defaultFPS)
        XCTAssertEqual(manifest.state, .recording)
    }

    // MARK: - Geometry

    /// **Odd dimensions cost quality for nothing.** H.264 and HEVC work in macroblocks, so an odd
    /// width makes the encoder pad the frame — and unlike an export, the recording is the master
    /// everything else is derived from.
    func testTheRecordedSizeIsAlwaysEven() {
        let awkward = [CGRect(x: 0, y: 0, width: 100.5, height: 66.5),
                       CGRect(x: 0, y: 0, width: 999, height: 501),
                       CGRect(x: 0, y: 0, width: 1, height: 1)]
        for rect in awkward {
            for scale in [CGFloat(1), 2, 3] {
                let size = RecordingGeometry.pixelSize(contentRect: rect, pointPixelScale: scale)
                XCTAssertEqual(size.width % 2, 0, "\(rect) @\(scale)")
                XCTAssertEqual(size.height % 2, 0, "\(rect) @\(scale)")
            }
        }
    }

    func testTheRecordedSizeIsNeverZero() {
        let size = RecordingGeometry.pixelSize(contentRect: .zero, pointPixelScale: 2)
        XCTAssertGreaterThanOrEqual(size.width, 2)
        XCTAssertGreaterThanOrEqual(size.height, 2)
    }

    /// Retina is captured at its real resolution. Downscaling at capture time throws away the
    /// detail a 2x zoom exists to show.
    func testRetinaIsCapturedAtFullResolution() {
        let size = RecordingGeometry.pixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), pointPixelScale: 2)
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 1200)
    }
}
