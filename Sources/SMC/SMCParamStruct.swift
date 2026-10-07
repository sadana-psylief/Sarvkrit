import Foundation

/// The wire format of an SMC request.
///
/// None of this is published by Apple. Every constant here was verified by probe against a
/// MacBook Pro (Mac14,9, M2 Pro, Darwin 25.6) before being written down, and the layout is
/// handled as a flat byte buffer rather than a Swift struct on purpose: `SMCKeyData_t` has
/// implicit padding in three places, and Swift's layout rules agreeing with the kernel's is
/// something to arrange rather than assume.
enum SMCParamStruct {
    /// `SMCKeyData_t`. Fixed at 80 bytes; the kernel rejects anything else.
    static let size = 80

    // Field offsets, in bytes, into that buffer.
    static let keyOffset = 0
    static let dataSizeOffset = 28
    static let dataTypeOffset = 32
    static let commandOffset = 42
    static let resultOffset = 40
    static let bytesOffset = 48

    /// `kSMCHandleYPCEvent` — the only selector any of this needs.
    static let selector: UInt32 = 2

    static let readBytes: UInt8 = 5
    static let writeBytes: UInt8 = 6
    static let readKeyInfo: UInt8 = 9

    /// `kSMCKeyNotFound`. A key this Mac does not have is an ordinary answer, not a fault.
    static let keyNotFound: UInt8 = 132

    /// The struct's own `UInt32` fields are in the kernel's native order…
    static func putNative(_ buffer: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    static func getNative(_ buffer: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16) | (UInt32(buffer[offset + 3]) << 24)
    }
}
