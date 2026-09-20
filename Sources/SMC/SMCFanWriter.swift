import Foundation

/// Holds the fans at a speed, or hands them back to macOS.
///
/// **This is the only code in the project that writes an SMC key, and it runs as root inside the
/// fan helper.** `FanWritePrivilegeTests` asserts that nothing in the app ever constructs it.
///
/// It re-derives everything. The app has already clamped the percentage and already knows each
/// fan's range, and none of that is taken on trust: a process running as root treats the number it
/// was handed as a suggestion, reads the ranges itself, and clamps again. The wire protocol
/// carrying a *percentage* rather than an RPM is the other half of that — an out-of-range fan
/// speed is not expressible from the other end at all.
struct SMCFanWriter {
    let read: (SMCKey) -> Double?
    let write: (Double, SMCKey) -> Bool

    init(read: @escaping (SMCKey) -> Double?, write: @escaping (Double, SMCKey) -> Bool) {
        self.read = read
        self.write = write
    }

    init(client: SMCClient) {
        self.init(read: { client.readDouble($0) }, write: { client.writeDouble($0, to: $1) })
    }

    /// Every target is worked out before anything is written, so a fan whose range the SMC will
    /// not report leaves the others untouched rather than half-applying a change.
    func hold(percent: Int) -> Bool {
        guard let count = fanCount() else { return false }
        guard count > 0 else { return true }

        let clamped = Double(min(max(percent, 0), 100))
        var targets: [(mode: SMCKey, target: SMCKey, rpm: Double)] = []

        for index in 0..<count {
            guard let modeKey = FanKey.mode(index), let targetKey = FanKey.target(index),
                  let minimumKey = FanKey.minimum(index), let maximumKey = FanKey.maximum(index),
                  let minimum = read(minimumKey), let maximum = read(maximumKey),
                  FanSpeedMath.isControllable(minimum: minimum, maximum: maximum)
            else { return false }

            targets.append((modeKey, targetKey,
                            FanSpeedMath.rpm(percent: clamped, minimum: minimum, maximum: maximum)))
        }

        var wroteEverything = true
        for target in targets {
            // Mode before target: a target written to a fan macOS is still driving is ignored.
            wroteEverything = write(1, target.mode) && wroteEverything
            wroteEverything = write(target.rpm, target.target) && wroteEverything
        }
        return wroteEverything
    }

    /// The safe direction, and the one that runs when something has already gone wrong — so it
    /// asks for nothing it can do without and gives up on no individual failure.
    ///
    /// **An unreadable `FNum` is not a reason to stop.** This runs precisely when the SMC has just
    /// misbehaved, and refusing to release because the coprocessor will not say how many fans it
    /// has would leave them forced with the helper on its way out — the single outcome this whole
    /// design exists to prevent. So a Mac that will not answer gets every addressable mode key
    /// written blind. A key that does not exist fails harmlessly.
    @discardableResult
    func release() -> Bool {
        let indices = fanCount().map { Array(0..<$0) } ?? Array(0..<10)
        var releasedEverything = true
        for index in indices {
            guard let modeKey = FanKey.mode(index) else { continue }
            releasedEverything = write(0, modeKey) && releasedEverything
        }
        return releasedEverything
    }

    private func fanCount() -> Int? {
        guard let count = read(FanKey.count).map({ Int($0) }), count >= 0 else { return nil }
        return min(count, 10)
    }
}
