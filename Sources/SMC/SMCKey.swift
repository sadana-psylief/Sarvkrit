import Foundation

/// A four-character SMC key, such as `F0Ac`.
///
/// Pure, and deliberately a type rather than a `String`: the SMC takes keys as a packed `UInt32`,
/// and a key that is three or five characters long packs into something that is still a valid
/// `UInt32` and still reads back a value. A typo would not fail — it would answer, with the wrong
/// number. Making the four-character rule a failable initialiser is what turns that into a `nil`.
struct SMCKey: Hashable, CustomStringConvertible {
    /// The four bytes packed big-endian, which is how the SMC spells a key.
    let code: UInt32

    init?(_ fourCharacterCode: String) {
        let bytes = Array(fourCharacterCode.utf8)
        // `utf8` rather than `unicodeScalars`: a multi-byte character would pass a scalar count
        // check and then overflow the four bytes the SMC has room for.
        guard bytes.count == 4, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        code = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The fan keys, which are the same on every Mac that has a fan at all.
///
/// `F<n>Ac` is what the fan is doing, `F<n>Mn`/`F<n>Mx` the range it can do it in, `F<n>Tg` the
/// speed it has been asked for and `F<n>Md` whether the SMC or somebody else is asking.
enum FanKey {
    /// How many fans this Mac has. Zero on every Apple Silicon MacBook Air, which is a fact about
    /// the machine rather than a failure to read.
    static let count = SMCKey("FNum")!

    static func actual(_ index: Int) -> SMCKey? { key(index, "Ac") }
    static func minimum(_ index: Int) -> SMCKey? { key(index, "Mn") }
    static func maximum(_ index: Int) -> SMCKey? { key(index, "Mx") }
    static func target(_ index: Int) -> SMCKey? { key(index, "Tg") }
    static func mode(_ index: Int) -> SMCKey? { key(index, "Md") }

    /// An SMC key is exactly four characters, so the index has exactly one digit to live in and a
    /// tenth fan has no unambiguous spelling. No shipping Mac has one. Callers must read the `nil`
    /// as "this fan cannot be addressed", never as a key they can go on to build by hand.
    private static func key(_ index: Int, _ suffix: String) -> SMCKey? {
        guard (0...9).contains(index) else { return nil }
        return SMCKey("F\(index)\(suffix)")
    }
}
