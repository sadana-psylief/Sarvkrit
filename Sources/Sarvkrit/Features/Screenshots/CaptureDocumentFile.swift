import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Reading and writing a Sarvkrit capture.
///
/// **The format is an ordinary PNG with two private chunks.** The IDAT is the flattened, annotated
/// image; `srKD` holds the annotation document as JSON and `srKB` holds the untouched base bitmap.
///
/// Why not the alternatives:
///
/// - **A JSON sidecar** breaks on the operation people actually perform on screenshots: dragging
///   them into a chat, or moving them. The moment the two files part company the edits are gone,
///   and nothing in the UI can warn about it.
/// - **A package or a zip** is invisible to every other app, and the entire point of a screenshot
///   is that Preview, Quick Look, Mail and the browser all open it.
///
/// The PNG gets both: decoders must skip chunks they don't recognise, so everyone else sees a
/// perfectly ordinary annotated screenshot while Sarvkrit sees a re-editable document.
///
/// The cost is roughly double the file size, since the base bitmap is stored twice. That is paid
/// only where it buys something: **plain save, copy and drag-out produce a flat PNG with no
/// chunks**, and only history entries and an explicit "save as re-editable" carry them.
///
/// Both chunk types are ancillary, private and **unsafe-to-copy**. The last of those is
/// deliberate: if another editor crops or resizes the image it is required to drop our chunks
/// rather than carry forward annotation coordinates that no longer describe the pixels. Stale
/// coordinates would put a redaction rectangle over the wrong part of the picture, which is a
/// security failure rather than a cosmetic one.
enum CaptureDocumentFile {
    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Screenshots")

    /// Lowercase first letter = ancillary, lowercase second = private, uppercase fourth =
    /// unsafe to copy.
    static let documentChunk = "srKD"
    static let baseChunk = "srKB"

    enum Failure: Error, Equatable {
        case cannotEncode
        case cannotDecode
    }

    // MARK: - Writing

    /// An ordinary PNG. What plain save, copy and drag-out produce.
    static func encodeFlat(_ image: CGImage) throws -> Data {
        guard let data = png(from: image) else { throw Failure.cannotEncode }
        return data
    }

    /// A re-editable PNG: flattened pixels, plus the document and the untouched base.
    static func encode(document: AnnotationDocument,
                       base: CGImage,
                       flattened: CGImage) throws -> Data {
        guard let flatData = png(from: flattened), let baseData = png(from: base) else {
            throw Failure.cannotEncode
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let documentData = try encoder.encode(document)

        return try PNGChunkCodec.inserting([
            .init(type: documentChunk, data: documentData),
            .init(type: baseChunk, data: baseData),
        ], into: flatData)
    }

    // MARK: - Reading

    struct Contents {
        /// Nil when the file isn't one of ours, or its annotation layer is unreadable.
        let document: AnnotationDocument?
        let base: CGImage?
        /// Always present: this is the image every other app sees.
        let flattened: CGImage
    }

    /// Reads a PNG, with or without our chunks.
    ///
    /// **Never throws for a well-formed PNG that simply isn't ours** — it comes back as a flat
    /// image with no document, and the editor opens it as a fresh single-layer capture. A damaged
    /// annotation layer degrades the same way: the pixels are the part the user cannot recreate.
    static func decode(_ data: Data) throws -> Contents {
        guard let flattened = image(from: data) else { throw Failure.cannotDecode }

        let chunks = (try? PNGChunkCodec.chunks(in: data)) ?? []
        let documentData = chunks.first { $0.type == documentChunk }?.data
        let baseData = chunks.first { $0.type == baseChunk }?.data

        var document: AnnotationDocument?
        if let documentData {
            do {
                document = try JSONDecoder().decode(AnnotationDocument.self, from: documentData)
            } catch {
                log.error("annotation layer unreadable, opening flat: \(error.localizedDescription, privacy: .public)")
            }
        }
        return Contents(document: document,
                        base: baseData.flatMap(image(from:)),
                        flattened: flattened)
    }

    /// Whether a file carries an annotation layer, without decoding the pixels.
    static func isReEditable(_ data: Data) -> Bool {
        ((try? PNGChunkCodec.chunks(in: data)) ?? []).contains { $0.type == documentChunk }
    }

    // MARK: - Image IO

    static func png(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
