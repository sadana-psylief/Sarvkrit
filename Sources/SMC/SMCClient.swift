import Foundation
import IOKit
import os

/// A connection to the System Management Controller.
///
/// Reading is unprivileged — no root, no password, no TCC prompt, and nothing leaves the Mac.
/// Writing is not, and this type deliberately does not offer it: the only code that writes an SMC
/// key is the root helper, and keeping the verb out of the app's reach means a bug in the app
/// cannot become a fan stuck at full speed.
///
/// Shaped after `SMARTReader` (every IOKit handle released on every path) and `ThermalSampler`
/// (a latched `isUnavailable`, never retried — the answer will not change before the next launch).
///
/// **One client, one queue.** The SMC is a single serialised coprocessor, and two concurrent
/// `IOConnectCallStructMethod`s against one connection is how you get a garbage read rather than
/// an error. An `SMCClient` is owned by exactly one serial queue and never shared across them.
final class SMCClient {
    // A literal subsystem rather than `AppIdentity.logSubsystem`: this file is compiled into the
    // root helper too, which cannot see the app's types.
    private static let log = Logger(subsystem: "ai.psylief.sarvkrit", category: "SMC")

    private var connection: io_connect_t = 0
    private(set) var isUnavailable = false

    init() {}
    deinit { close() }

    @discardableResult
    func open() -> Bool {
        guard connection == 0 else { return true }
        guard !isUnavailable else { return false }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            isUnavailable = true
            Self.log.error("no AppleSMC service on this Mac")
            return false
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            isUnavailable = true
            connection = 0
            Self.log.error("IOServiceOpen failed: \(result, privacy: .public)")
            return false
        }
        return true
    }

    func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    /// The type and byte count the SMC says a key has. Nil when the key is absent — which for the
    /// fan keys is the ordinary answer on a Mac that has no fans.
    func keyInfo(_ key: SMCKey) -> (type: UInt32, size: Int)? {
        var input = [UInt8](repeating: 0, count: SMCParamStruct.size)
        SMCParamStruct.putNative(&input, SMCParamStruct.keyOffset, key.code)
        input[SMCParamStruct.commandOffset] = SMCParamStruct.readKeyInfo

        guard let output = call(input) else { return nil }
        let size = Int(SMCParamStruct.getNative(output, SMCParamStruct.dataSizeOffset))
        let type = SMCParamStruct.getNative(output, SMCParamStruct.dataTypeOffset)
        guard size > 0, size <= 32 else { return nil }
        return (type, size)
    }

    func readDouble(_ key: SMCKey) -> Double? {
        guard let info = keyInfo(key) else { return nil }

        var input = [UInt8](repeating: 0, count: SMCParamStruct.size)
        SMCParamStruct.putNative(&input, SMCParamStruct.keyOffset, key.code)
        SMCParamStruct.putNative(&input, SMCParamStruct.dataSizeOffset, UInt32(info.size))
        SMCParamStruct.putNative(&input, SMCParamStruct.dataTypeOffset, info.type)
        input[SMCParamStruct.commandOffset] = SMCParamStruct.readBytes

        guard let output = call(input) else { return nil }
        let bytes = Array(output[SMCParamStruct.bytesOffset..<(SMCParamStruct.bytesOffset + info.size)])
        return SMCValueCodec.decode(type: info.type, bytes: bytes)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        guard connection != 0 || open() else { return nil }

        var output = [UInt8](repeating: 0, count: SMCParamStruct.size)
        var outputSize = SMCParamStruct.size
        let result = input.withUnsafeBytes { inputPointer in
            output.withUnsafeMutableBytes { outputPointer in
                IOConnectCallStructMethod(
                    connection, SMCParamStruct.selector,
                    inputPointer.baseAddress, SMCParamStruct.size,
                    outputPointer.baseAddress, &outputSize)
            }
        }
        guard result == kIOReturnSuccess else { return nil }
        // A key this Mac does not carry comes back as a result code, not an IOKit error.
        guard output[SMCParamStruct.resultOffset] != SMCParamStruct.keyNotFound else { return nil }
        return output
    }
}
