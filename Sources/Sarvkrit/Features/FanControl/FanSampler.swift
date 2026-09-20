import Foundation

/// Turns SMC key reads into `FanHardware`.
///
/// Takes its reads as a closure so the decisions worth testing — no fans versus no answer, a mode
/// key that is absent versus one reading zero — can be tested on a machine that cannot reproduce
/// them. The same reasoning as `ThermalClassification`: the sampler around it needs hardware that
/// answers; this needs a dictionary.
final class FanSampler {
    private let readKey: (SMCKey) -> Double?
    private let client: SMCClient?

    /// The real thing.
    init() {
        let client = SMCClient()
        client.open()
        self.client = client
        self.readKey = { [weak client] key in client?.readDouble(key) }
    }

    /// A stub, for tests.
    init(read: @escaping (SMCKey) -> Double?) {
        self.readKey = read
        self.client = nil
    }

    deinit { client?.close() }

    func read() -> FanHardware {
        guard let count = readKey(FanKey.count).map({ Int($0) }) else { return .unreadable }
        guard count > 0 else { return .fanless }

        // An SMC key has exactly one digit for the index. A Mac claiming more fans than that has
        // more than we can address, so report the ones we can reach rather than inventing names.
        return .fans((0..<min(count, 10)).map { index in
            FanReading(
                index: index,
                rpm: FanKey.actual(index).flatMap(readKey),
                minimum: FanKey.minimum(index).flatMap(readKey),
                maximum: FanKey.maximum(index).flatMap(readKey),
                isForced: FanKey.mode(index).flatMap(readKey).map { $0 != 0 })
        })
    }
}
