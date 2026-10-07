import Foundation

/// What one fan is doing, and the range it can do it in.
struct FanReading: Equatable, Identifiable {
    var index: Int
    /// Nil when the SMC would not say. **Zero is a reading, not an absence** — Apple Silicon
    /// stops its fans when the Mac is cool, so zero is the state they are in most of the time.
    var rpm: Double?
    var minimum: Double?
    var maximum: Double?
    /// Nil when this Mac has no mode key, which is not the same as "nobody is forcing it". The
    /// difference decides whether we offer to release a fan somebody else left held.
    var isForced: Bool?

    var id: Int { index }

    var isControllable: Bool {
        guard let minimum, let maximum else { return false }
        return FanSpeedMath.isControllable(minimum: minimum, maximum: maximum)
    }
}

/// What this Mac has to say about fans at all.
///
/// The distinction that matters is the first two cases. A MacBook Air has no fans and says so
/// clearly; an SMC that will not answer is a failure. Collapsing them would tell Air owners
/// something had gone wrong, and it would tell everyone else nothing had.
enum FanHardware: Equatable {
    /// `FNum` reads zero. Every Apple Silicon MacBook Air. A fact, not a fault.
    case fanless
    /// The SMC did not answer. This one is an error.
    case unreadable
    case fans([FanReading])
}
