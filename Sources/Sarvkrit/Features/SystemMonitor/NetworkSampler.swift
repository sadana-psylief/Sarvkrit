import Darwin
import Foundation

/// Cumulative bytes across every physical interface.
struct NetworkCounters: Equatable {
    var received: UInt64
    var sent: UInt64
}

/// Walks the interface list and sums its byte counters.
///
/// `getifaddrs` allocates the whole linked list, which ARC does not own — `freeifaddrs` is
/// mandatory or every sample leaks the entire list.
///
/// Loopback is excluded deliberately: local traffic between processes on this Mac is not network
/// activity in any sense the user means, and on a machine running a local server it dwarfs the real
/// numbers.
enum NetworkSampler {
    static func read() -> NetworkCounters? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            // Byte counters live on the link-layer entry; the AF_INET/AF_INET6 entries for the same
            // interface carry addresses, and counting all three triples every figure.
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo") else { continue }

            guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else {
                continue
            }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }

        return NetworkCounters(received: received, sent: sent)
    }
}
