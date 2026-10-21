import Darwin
import Foundation

// The modes both harnesses run, each compiled into one module with its app's tunnel sources. A
// harness ends through _exit: exit() runs OPENSSL_cleanup while a tunnel's teardown can still be
// inside libssh2, which crashed about one run in 40.

nonisolated protocol HarnessTunnel: Sendable {
    var localPort: Int { get }
    var isRunning: Bool { get }
    func close()
}

nonisolated struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

nonisolated struct HarnessOptions: Sendable {
    var mode = "connect"
    var host = "127.0.0.1"
    var port = 22
    var user = "tablepro"
    var auth = "password"
    var password: String?
    var keyFile: String?
    var keyMemory: String?
    var passphrase: String?
    var agentSocket: String?
    var totpSecret: String?
    var kbdintAnswer: String?
    var jumps: [String] = []
    var jumpKey: String?
    var jumpPassphrase: String?
    var target = "redis:6379"
    var count = 1
    var marker: String?
    var waitSeconds = 75
    var deadlineSeconds = 60
    var knownHostsDirectory = NSTemporaryDirectory()

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { throw HarnessFailure(description: "\(flag) needs a value") }
            let value = arguments[index + 1]
            index += 2
            switch flag {
            case "--mode": mode = value
            case "--host": host = value
            case "--port": port = try Self.number(value, flag)
            case "--user": user = value
            case "--auth": auth = value
            case "--password": password = value
            case "--key-file": keyFile = value
            case "--key-memory": keyMemory = value
            case "--passphrase": passphrase = value
            case "--agent-socket": agentSocket = value
            case "--totp-secret": totpSecret = value
            case "--kbdint-answer": kbdintAnswer = value
            case "--jump": jumps.append(value)
            case "--jump-key": jumpKey = value
            case "--jump-passphrase": jumpPassphrase = value
            case "--target": target = value
            case "--count": count = try Self.number(value, flag)
            case "--marker": marker = value
            case "--wait": waitSeconds = try Self.number(value, flag)
            case "--deadline": deadlineSeconds = try Self.number(value, flag)
            case "--known-hosts": knownHostsDirectory = value
            default: throw HarnessFailure(description: "unknown option \(flag)")
            }
        }
    }

    static func endpoint(_ text: String) throws -> (host: String, port: Int) {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else {
            throw HarnessFailure(description: "expected host:port, got \(text)")
        }
        return (String(text[..<colon]), port)
    }

    private static func number(_ text: String, _ flag: String) throws -> Int {
        guard let value = Int(text), value > 0 else { throw HarnessFailure(description: "\(flag) takes a positive number") }
        return value
    }
}

nonisolated enum Output {
    static func emit(_ line: String) {
        let flat = line.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        FileHandle.standardOutput.write(Data((flat + "\n").utf8))
    }

    static func finish(_ line: String, code: Int32) -> Never {
        emit(line)
        _exit(code)
    }

    static func errorLine(_ error: any Error) -> String {
        let shown = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "ERROR \(String(describing: error)) | \(shown)"
    }

    static func armWatchdog(seconds: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
            Output.finish("ERROR harness: no result within \(seconds)s", code: 3)
        }
    }
}

nonisolated enum LocalClient {
    static let ioTimeoutSeconds = 10

    static func open(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HarnessFailure(description: "socket: \(lastError())") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = loopback(port: port)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let reason = lastError()
            Darwin.close(fd)
            throw HarnessFailure(description: "connect to 127.0.0.1:\(port): \(reason)")
        }
        return fd
    }

    static func sendPing(_ fd: Int32) throws {
        let request = Array("PING\r\n".utf8)
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { throw HarnessFailure(description: "send PING: \(lastError())") }
    }

    static func expectPong(_ fd: Int32) throws {
        var reply: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64)
        while !reply.contains(UInt8(ascii: "\n")) {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                reply.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                throw HarnessFailure(description: "the tunnel closed the client after \(reply.count) bytes")
            } else {
                throw HarnessFailure(description: "recv: \(lastError())")
            }
        }
        let text = String(bytes: reply, encoding: .utf8) ?? reply.description
        guard text == "+PONG\r\n" else { throw HarnessFailure(description: "expected +PONG, got \(text.debugDescription)") }
    }

    static func roundTrip(port: Int) throws {
        let fd = try open(port: port)
        defer { Darwin.close(fd) }
        try sendPing(fd)
        try expectPong(fd)
    }

    // The port is free when this returns, not reserved: whoever binds it next can still lose it.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HarnessFailure(description: "socket: \(lastError())") }
        defer { Darwin.close(fd) }
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw HarnessFailure(description: "bind 127.0.0.1:0: \(lastError())") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { throw HarnessFailure(description: "getsockname: \(lastError())") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}

nonisolated enum TunnelHarness {
    typealias Opener = @Sendable (HarnessOptions) async throws -> any HarnessTunnel

    static func options() -> HarnessOptions {
        do {
            return try HarnessOptions(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            Output.finish("ERROR harness: \(error)", code: 3)
        }
    }

    static func run(_ open: @escaping Opener) async -> Never {
        let options = options()
        Output.armWatchdog(seconds: options.deadlineSeconds)

        switch options.mode {
        case "selftest":
            Output.finish("HARNESS ok", code: 0)
        case "connect":
            await connect(options, open: open)
        case "clients":
            await clients(options, open: open)
        case "tunnels":
            await tunnels(options, open: open)
        case "loss":
            await loss(options, open: open)
        default:
            Output.finish("ERROR harness: unknown --mode \(options.mode)", code: 3)
        }
    }

    static func connect(_ options: HarnessOptions, open: Opener) async -> Never {
        let tunnel = await openOrFinish(options, open: open)
        do {
            try LocalClient.roundTrip(port: tunnel.localPort)
        } catch {
            Output.finish("ERROR relay: \(error)", code: 1)
        }
        tunnel.close()
        Output.finish("CONNECTED", code: 0)
    }

    // Every client is connected before any sends, so all of them hold a channel at the same time.
    static func clients(_ options: HarnessOptions, open: Opener) async -> Never {
        let tunnel = await openOrFinish(options, open: open)
        var sockets: [Int32] = []
        do {
            for _ in 0..<options.count {
                let fd = try LocalClient.open(port: tunnel.localPort)
                sockets.append(fd)
            }
            for fd in sockets {
                try LocalClient.sendPing(fd)
            }
        } catch {
            Output.finish("ERROR relay: client \(sockets.count + 1) of \(options.count): \(error)", code: 1)
        }
        var answered = 0
        var firstFailure: String?
        for fd in sockets {
            do {
                try LocalClient.expectPong(fd)
                answered += 1
            } catch {
                firstFailure = firstFailure ?? "\(error)"
            }
            Darwin.close(fd)
        }
        tunnel.close()
        guard answered == options.count else {
            Output.finish("ERROR relay: \(answered) of \(options.count) clients answered; \(firstFailure ?? "")", code: 1)
        }
        Output.finish("CONNECTED clients=\(answered)", code: 0)
    }

    static func tunnels(_ options: HarnessOptions, open: @escaping Opener) async -> Never {
        let opened: [any HarnessTunnel]
        do {
            opened = try await withThrowingTaskGroup(of: (any HarnessTunnel).self) { group in
                for _ in 0..<options.count {
                    group.addTask { try await open(options) }
                }
                var collected: [any HarnessTunnel] = []
                for try await tunnel in group {
                    collected.append(tunnel)
                }
                return collected
            }
        } catch {
            Output.finish(Output.errorLine(error), code: 1)
        }
        for (index, tunnel) in opened.enumerated() {
            do {
                try LocalClient.roundTrip(port: tunnel.localPort)
            } catch {
                Output.finish("ERROR relay: tunnel \(index + 1) of \(opened.count): \(error)", code: 1)
            }
        }
        opened.forEach { $0.close() }
        Output.finish("CONNECTED tunnels=\(opened.count)", code: 0)
    }

    // CPU is the whole process over the wait: a relay that spins on a dead transport shows here.
    static func loss(_ options: HarnessOptions, open: Opener) async -> Never {
        guard let marker = options.marker else { Output.finish("ERROR harness: loss needs --marker", code: 3) }
        let relaying = await openOrFinish(options, open: open)
        let held: Int32
        do {
            held = try LocalClient.open(port: relaying.localPort)
            try LocalClient.sendPing(held)
            try LocalClient.expectPong(held)
        } catch {
            Output.finish("ERROR relay: \(error)", code: 1)
        }
        let idle = await openOrFinish(options, open: open)
        do {
            try LocalClient.roundTrip(port: idle.localPort)
        } catch {
            Output.finish("ERROR relay: \(error)", code: 1)
        }
        Output.emit("READY")

        while !FileManager.default.fileExists(atPath: marker) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let cpuAtStart = cpuSeconds()
        var relayingStopped: Duration?
        var idleStopped: Duration?
        while relayingStopped == nil || idleStopped == nil, start.duration(to: clock.now) < .seconds(options.waitSeconds) {
            if relayingStopped == nil, !relaying.isRunning { relayingStopped = start.duration(to: clock.now) }
            if idleStopped == nil, !idle.isRunning { idleStopped = start.duration(to: clock.now) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let cpu = cpuSeconds() - cpuAtStart
        Darwin.close(held)
        Output.finish(
            "LOSS relaying=\(seconds(relayingStopped)) idle=\(seconds(idleStopped)) cpu=\(String(format: "%.2f", cpu))",
            code: 0
        )
    }

    private static func openOrFinish(_ options: HarnessOptions, open: Opener) async -> any HarnessTunnel {
        do {
            return try await open(options)
        } catch {
            Output.finish(Output.errorLine(error), code: 1)
        }
    }

    private static func seconds(_ duration: Duration?) -> String {
        guard let duration else { return "none" }
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f", value)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}
