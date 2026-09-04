import CoreGraphics
import Foundation
import Vision
import os

/// Reading text and QR codes out of an image.
///
/// On-device and offline: Vision's text recognition needs no entitlement, no network and no
/// permission of its own. The app is not sandboxed, so there is nothing to declare.
///
/// **The ordering is ours and the recognition is Apple's**, and the ordering is the part that
/// decides whether a paste is usable — see `ReadingOrder`.
enum TextRecognizer {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    struct Barcode: Equatable {
        let payload: String
        let symbology: String
        /// Image pixels, top-left origin.
        let rect: CGRect
    }

    struct Result {
        let fragments: [ReadingOrder.Fragment]
        let barcodes: [Barcode]

        var text: String { ReadingOrder.text(from: fragments) }
        var isEmpty: Bool { fragments.isEmpty && barcodes.isEmpty }
    }

    /// Languages the installed OS can actually recognise.
    static var supportedLanguages: [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
    }

    /// Runs text and barcode recognition in **one** pass over the image — one decode, two
    /// requests, rather than handing the same bitmap to Vision twice.
    ///
    /// - Parameter level: `.fast` when only the geometry is wanted (the highlighter's line
    ///   snapping), `.accurate` when the strings matter.
    static func recognize(_ image: CGImage,
                          languages: [String] = [],
                          level: VNRequestTextRecognitionLevel = .accurate,
                          includeBarcodes: Bool = true) -> Result {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = level
        textRequest.usesLanguageCorrection = level == .accurate
        textRequest.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty { textRequest.recognitionLanguages = languages }

        var requests: [VNRequest] = [textRequest]
        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.qr, .microQR, .aztec, .dataMatrix]
        if includeBarcodes { requests.append(barcodeRequest) }

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)
        } catch {
            log.error("recognition failed: \(error.localizedDescription, privacy: .public)")
            return Result(fragments: [], barcodes: [])
        }

        let size = CGSize(width: image.width, height: image.height)
        let fragments = (textRequest.results ?? []).compactMap { observation -> ReadingOrder.Fragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return ReadingOrder.Fragment(text: candidate.string,
                                         rect: imageRect(observation.boundingBox, in: size))
        }
        let barcodes = includeBarcodes
            ? (barcodeRequest.results ?? []).compactMap { observation -> Barcode? in
                guard let payload = observation.payloadStringValue else { return nil }
                return Barcode(payload: payload,
                               symbology: observation.symbology.rawValue,
                               rect: imageRect(observation.boundingBox, in: size))
              }
            : []

        return Result(fragments: fragments, barcodes: barcodes)
    }

    /// **Vision reports normalised boxes with a bottom-left origin** — the opposite of everything
    /// else in this feature, which is top-left in image pixels. Converted here, at the boundary,
    /// and nowhere else afterwards.
    static func imageRect(_ normalised: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalised.minX * size.width,
               y: (1 - normalised.maxY) * size.height,
               width: normalised.width * size.width,
               height: normalised.height * size.height)
    }
}

/// Text-line geometry for one image, built once.
///
/// Shared by the highlighter's line snapping and the editor's Copy Text action, so an image is
/// never run through Vision twice. Uses `.fast`, because what this is for is boxes rather than
/// strings, and fast is several times quicker.
final class TextGeometryIndex {
    struct Line: Equatable {
        let rect: CGRect
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var isReady = false

    /// Builds off the main thread. The highlighter **never waits on this** — if it isn't ready
    /// when the user starts dragging, the bar uses its preset height and the drag feels normal.
    func build(from image: CGImage, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = TextRecognizer.recognize(image, level: .fast, includeBarcodes: false)
            let grouped = ReadingOrder.lines(from: result.fragments).map { fragments -> Line in
                let rects = fragments.map(\.rect)
                let minX = rects.map(\.minX).min() ?? 0
                let minY = rects.map(\.minY).min() ?? 0
                let maxX = rects.map(\.maxX).max() ?? 0
                let maxY = rects.map(\.maxY).max() ?? 0
                return Line(rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                            text: fragments.map(\.text).joined(separator: " "))
            }
            DispatchQueue.main.async {
                self?.lines = grouped
                self?.isReady = true
                completion?()
            }
        }
    }

    /// Injects lines directly, so the snapping rules can be tested without running Vision.
    func setLinesForTesting(_ lines: [Line]) {
        self.lines = lines
        self.isReady = true
    }

    /// The line whose vertical band contains — or is nearest to — a point. Pure over `lines`.
    func nearestLine(to point: CGPoint, maxDistance: CGFloat) -> Line? {
        let containing = lines.filter { point.y >= $0.rect.minY && point.y <= $0.rect.maxY }
        if let best = containing.min(by: { abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y) }) {
            return best
        }
        return lines
            .filter { abs($0.rect.midY - point.y) <= maxDistance }
            .min { abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y) }
    }

    /// The bar a highlighter drag should produce.
    ///
    /// Snapped to a detected line's height and vertical centre when there is one, so dragging only
    /// extends it sideways — which is what makes a highlighter feel like a marker rather than a
    /// rectangle tool. Falls back to `fallbackHeight` whenever the index isn't ready or nothing is
    /// near, which is what keeps it usable on a chart.
    func snappedBar(from start: CGPoint, to end: CGPoint,
                    fallbackHeight: CGFloat) -> (rect: CGRect, snapped: Bool) {
        let minX = min(start.x, end.x), maxX = max(start.x, end.x)
        guard isReady,
              let line = nearestLine(to: start, maxDistance: fallbackHeight * 1.5) else {
            let midY = (start.y + end.y) / 2
            return (CGRect(x: minX, y: midY - fallbackHeight / 2,
                           width: maxX - minX, height: fallbackHeight), false)
        }
        return (CGRect(x: minX, y: line.rect.minY, width: maxX - minX, height: line.rect.height),
                true)
    }
}
