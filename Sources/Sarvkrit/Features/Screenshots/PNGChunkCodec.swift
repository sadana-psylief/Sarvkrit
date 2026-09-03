import Foundation

/// Reading and writing private PNG chunks.
///
/// **`ImageIO` cannot write private chunks**, so this is hand-rolled — about eighty lines of pure
/// `Data` in, `Data` out, which is also what makes it fully testable.
///
/// A PNG is an 8-byte signature followed by chunks of `length | type | data | crc`. Decoders are
/// required by the spec to skip chunks they don't recognise, which is the whole reason this
/// approach works: a Sarvkrit capture stays an ordinary PNG everywhere else in the system while
/// carrying its annotation layer inside itself.
enum PNGChunkCodec {

    struct Chunk: Equatable {
        let type: String
        let data: Data
    }

    enum Failure: Error, Equatable {
        case notAPNG
        case truncated
        case noEnd
    }

    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    /// Every chunk in a PNG.
    ///
    /// **A chunk whose CRC doesn't match is skipped, not thrown.** A damaged annotation layer must
    /// degrade to "opens as a flat image", never to "this file is broken" — the pixels are the
    /// part the user cannot recreate.
    static func chunks(in png: Data) throws -> [Chunk] {
        guard png.count > signature.count, png.prefix(signature.count) == signature else {
            throw Failure.notAPNG
        }

        var chunks: [Chunk] = []
        var index = signature.count
        while index + 8 <= png.count {
            let length = Int(readUInt32(png, at: index))
            let typeStart = index + 4
            let dataStart = typeStart + 4
            let crcStart = dataStart + length
            guard crcStart + 4 <= png.count else { throw Failure.truncated }

            let type = String(decoding: png[typeStart..<dataStart], as: UTF8.self)
            let payload = Data(png[dataStart..<crcStart])
            let stored = readUInt32(png, at: crcStart)
            let computed = crc32(png[typeStart..<crcStart])

            if stored == computed {
                chunks.append(Chunk(type: type, data: payload))
            }
            if type == "IEND" { break }
            index = crcStart + 4
        }
        return chunks
    }

    /// Inserts chunks immediately before `IEND`, which is where ancillary data belongs.
    static func inserting(_ newChunks: [Chunk], into png: Data) throws -> Data {
        guard png.count > signature.count, png.prefix(signature.count) == signature else {
            throw Failure.notAPNG
        }
        guard let endStart = offsetOfIEND(in: png) else { throw Failure.noEnd }

        var result = Data(png[0..<endStart])
        for chunk in newChunks { result.append(encoded(chunk)) }
        result.append(png[endStart...])
        return result
    }

    static func removing(types: Set<String>, from png: Data) throws -> Data {
        guard png.count > signature.count, png.prefix(signature.count) == signature else {
            throw Failure.notAPNG
        }
        var result = signature
        var index = signature.count
        while index + 8 <= png.count {
            let length = Int(readUInt32(png, at: index))
            let typeStart = index + 4
            let crcStart = typeStart + 4 + length
            guard crcStart + 4 <= png.count else { throw Failure.truncated }
            let type = String(decoding: png[typeStart..<(typeStart + 4)], as: UTF8.self)
            if !types.contains(type) {
                result.append(png[index..<(crcStart + 4)])
            }
            index = crcStart + 4
            if type == "IEND" { break }
        }
        return result
    }

    static func encoded(_ chunk: Chunk) -> Data {
        var out = Data()
        out.append(uint32(UInt32(chunk.data.count)))
        let typeAndData = Data(chunk.type.utf8) + chunk.data
        out.append(typeAndData)
        out.append(uint32(crc32(typeAndData)))
        return out
    }

    private static func offsetOfIEND(in png: Data) -> Int? {
        var index = signature.count
        while index + 8 <= png.count {
            let length = Int(readUInt32(png, at: index))
            let typeStart = index + 4
            guard typeStart + 4 <= png.count else { return nil }
            let type = String(decoding: png[typeStart..<(typeStart + 4)], as: UTF8.self)
            if type == "IEND" { return index }
            index = typeStart + 4 + length + 4
        }
        return nil
    }

    // MARK: - Primitives

    private static func readUInt32<C: Collection>(_ data: C, at offset: Int) -> UInt32
        where C.Element == UInt8, C.Index == Int {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
             | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
              UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    /// The standard PNG/zlib CRC-32.
    static func crc32<C: Sequence>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}
