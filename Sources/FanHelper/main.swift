import Darwin
import Foundation

// The root half of Sarvkrit's fan control.
//
// It holds no policy: no curve, no threshold, no hysteresis, no temperature. The app decides what
// the fans should do and sends a percentage; this writes it. Duplicating the decision inside a
// process running as root would be the same logic wrong in two places, one of them privileged.
//
// **Its default on every path is macOS.** The connection dropping, the app dying, a lapsed
// heartbeat, a signal, a failed write — all of them land in `surrender()`, which hands the fans
// back and exits. Getting stuck holding a fan is the failure this whole file is shaped against.

setvbuf(stdout, nil, _IOLBF, 0)

guard let options = FanHelperOptions(arguments: Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: needs --socket, --owner-pid, --owner-uid\n".utf8))
    exit(64)
}

let client = SMCClient()
guard client.open() else {
    FileHandle.standardError.write(Data("cannot open the SMC\n".utf8))
    exit(70)
}
let writer = SMCFanWriter(client: client)

/// The only way out. Hands the fans back first, always.
func surrender(_ code: Int32) -> Never {
    writer.release()
    client.close()
    exit(code)
}

if options.releaseAndExit {
    surrender(0)
}

// A write to a socket the app has closed must come back as an error, not kill the process before
// it can put the fans back.
signal(SIGPIPE, SIG_IGN)
// Retained deliberately: a DispatchSourceSignal that goes out of scope stops firing, and the
// signal is already ignored by then — so the helper would sit there holding the fans.
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { surrender(0) }
    source.resume()
    signalSources.append(source)
}

// MARK: - The socket

// The app listens and this connects out, rather than the other way round. A root process that
// binds and accepts is a root process responsible for filtering everyone who reaches it; this way
// it opens exactly one outbound connection and never listens at all.
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(options.socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { surrender(64) }
withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.copyBytes(from: pathBytes)
}

// The socket must belong to the user we were told we are working for. A socket owned by anyone
// else is not the app's, whatever the path says.
var info = stat()
guard stat(options.socketPath, &info) == 0, info.st_uid == options.ownerUID else { surrender(77) }

let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard descriptor >= 0 else { surrender(74) }

let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { surrender(74) }

// Blocking reads wake up once a second so the liveness checks below still run on a quiet socket.
var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

_ = "HELLO 1\n".withCString { write(descriptor, $0, strlen($0)) }

// MARK: - The loop

/// `CLOCK_UPTIME_RAW` does not advance while the Mac is asleep — the man page says so in as many
/// words. A wall-clock deadline would expire during any sleep longer than the idle timeout, so the
/// helper would quit on every lid-close and the user would get a password prompt on every wake.
func uptimeSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

var lastHeard = uptimeSeconds()
var pending = Data()
var buffer = [UInt8](repeating: 0, count: 256)

while true {
    // Four independent ways out, three of them free.
    if kill(options.ownerPID, 0) != 0 && errno == ESRCH { surrender(0) }
    if uptimeSeconds() - lastHeard > options.idleTimeout { surrender(0) }

    let count = read(descriptor, &buffer, buffer.count)
    if count == 0 { surrender(0) }                       // the app closed, or died
    if count < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
        surrender(74)
    }

    lastHeard = uptimeSeconds()
    pending.append(contentsOf: buffer[0..<count])

    // An unbounded buffer is an unbounded allocation in a root process. A line this long is not
    // something the app sends, so whatever is on the other end is not behaving.
    if pending.count > FanWire.maximumLineLength * 4 { surrender(65) }

    while let newline = pending.firstIndex(of: 0x0A) {
        let line = String(decoding: pending[pending.startIndex...newline], as: UTF8.self)
        pending.removeSubrange(pending.startIndex...newline)

        guard let command = FanWire.parse(line) else {
            _ = "ERR malformed\n".withCString { write(descriptor, $0, strlen($0)) }
            continue
        }

        switch command {
        case let .set(percent):
            // The percentage is clamped again inside the writer, against ranges it reads itself.
            let ok = writer.hold(percent: percent)
            _ = (ok ? "OK\n" : "ERR write\n").withCString { write(descriptor, $0, strlen($0)) }
            // A fan we cannot write is a fan we cannot promise anything about.
            if !ok { surrender(70) }
        case .auto:
            let ok = writer.release()
            _ = (ok ? "OK\n" : "ERR write\n").withCString { write(descriptor, $0, strlen($0)) }
        case .ping:
            _ = "OK\n".withCString { write(descriptor, $0, strlen($0)) }
        case .quit:
            surrender(0)
        }
    }
}
