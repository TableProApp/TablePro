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
    var rounds = 500
    var sizeMegabytes: Int?
    var marker: String?
    var waitSeconds: Int?
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
            case "--count": count = try Self.number(value, flag, allowZero: true)
            case "--rounds": rounds = try Self.number(value, flag)
            case "--size": sizeMegabytes = try Self.number(value, flag)
            case "--marker": marker = value
            case "--wait": waitSeconds = try Self.number(value, flag)
            case "--deadline": deadlineSeconds = try Self.number(value, flag)
            case "--known-hosts": knownHostsDirectory = value
            default: throw HarnessFailure(description: "unknown option \(flag)")
            }
        }
        // Only idle has a use for a tunnel with no client: it is the baseline the relays add to.
        guard count >= 1 || mode == "idle" else { throw HarnessFailure(description: "--count takes a positive number") }
    }

    static func endpoint(_ text: String) throws -> (host: String, port: Int) {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else {
            throw HarnessFailure(description: "expected host:port, got \(text)")
        }
        return (String(text[..<colon]), port)
    }

    private static func number(_ text: String, _ flag: String, allowZero: Bool = false) throws -> Int {
        guard let value = Int(text), value > 0 || (allowZero && value == 0) else {
            throw HarnessFailure(description: "\(flag) takes a positive number")
        }
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
    // A bulk value is tens of megabytes: one slow read or write through the tunnel can pass 10 s.
    static let bulkTimeoutSeconds = 60

    static func open(port: Int, timeoutSeconds: Int = LocalClient.ioTimeoutSeconds) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HarnessFailure(description: "socket: \(lastError())") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
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

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress?.advanced(by: offset), $0.count - offset, 0) }
            if sent > 0 {
                offset += sent
            } else if sent < 0, errno == EINTR {
                continue
            } else {
                throw HarnessFailure(description: "send after \(offset) of \(bytes.count) bytes: \(lastError())")
            }
        }
    }

    // One byte at a time, so nothing after the line is taken off the socket.
    static func readLine(_ fd: Int32) throws -> String {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.recv(fd, &byte, 1, 0)
            if count == 1 {
                if byte == UInt8(ascii: "\n") { break }
                line.append(byte)
            } else if count == 0 {
                throw HarnessFailure(description: "the tunnel closed the client after \(line.count) bytes of a line")
            } else if errno != EINTR {
                throw HarnessFailure(description: "recv: \(lastError())")
            }
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        return String(bytes: line, encoding: .utf8) ?? ""
    }

    // Reads exactly count bytes, each chunk over the last in buffer.
    static func receiveExactly(_ fd: Int32, count: Int, into buffer: inout [UInt8]) throws {
        var remaining = count
        while remaining > 0 {
            let received = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, min($0.count, remaining), 0) }
            if received > 0 {
                remaining -= received
            } else if received == 0 {
                throw HarnessFailure(description: "the tunnel closed the client with \(remaining) of \(count) bytes to go")
            } else if errno != EINTR {
                throw HarnessFailure(description: "recv with \(remaining) of \(count) bytes to go: \(lastError())")
            }
        }
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

// Raw RESP to the redis behind the tunnel.
nonisolated enum RedisClient {
    static func command(_ arguments: [String], valueLength: Int? = nil) -> [UInt8] {
        var text = "*\(arguments.count + (valueLength == nil ? 0 : 1))\r\n"
        for argument in arguments {
            text += "$\(argument.utf8.count)\r\n\(argument)\r\n"
        }
        if let valueLength {
            text += "$\(valueLength)\r\n"
        }
        return Array(text.utf8)
    }

    // The value goes out from its own buffer rather than being copied into the request.
    static func set(_ fd: Int32, key: String, value: [UInt8]) throws {
        try LocalClient.sendAll(fd, command(["SET", key], valueLength: value.count))
        try LocalClient.sendAll(fd, value)
        try LocalClient.sendAll(fd, Array("\r\n".utf8))
        let reply = try LocalClient.readLine(fd)
        guard reply == "+OK" else { throw HarnessFailure(description: "SET \(key): expected +OK, got \(reply.debugDescription)") }
    }

    static func get(_ fd: Int32, key: String, buffer: inout [UInt8]) throws -> Int {
        try LocalClient.sendAll(fd, command(["GET", key]))
        let header = try LocalClient.readLine(fd)
        guard header.first == "$", let length = Int(header.dropFirst()), length >= 0 else {
            throw HarnessFailure(description: "GET \(key): expected a bulk string, got \(header.debugDescription)")
        }
        try LocalClient.receiveExactly(fd, count: length, into: &buffer)
        var trailer = [UInt8](repeating: 0, count: 2)
        try LocalClient.receiveExactly(fd, count: 2, into: &trailer)
        guard trailer == Array("\r\n".utf8) else {
            throw HarnessFailure(description: "GET \(key): \(length) bytes did not end in CRLF")
        }
        return length
    }

    static func delete(_ fd: Int32, key: String) throws {
        try LocalClient.sendAll(fd, command(["DEL", key]))
        let reply = try LocalClient.readLine(fd)
        guard reply.hasPrefix(":") else { throw HarnessFailure(description: "DEL \(key): got \(reply.debugDescription)") }
    }
}

// Whole-process counters. The iOS harness reads neither and prints n/a.
nonisolated enum ProcessCounters {
    static func wakeups() -> UInt64? {
        #if os(macOS)
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return nil }
        return info.ri_interrupt_wkups + info.ri_pkg_idle_wkups
        #else
        return nil
        #endif
    }

    static func threads() -> Int? {
        #if os(macOS)
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let threads = list else { return nil }
        for index in 0..<Int(count) {
            mach_port_deallocate(mach_task_self_, threads[index])
        }
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: threads),
            vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride)
        )
        return Int(count)
        #else
        return nil
        #endif
    }
}

// Shared by the concurrent mode's client threads; every field is read and written under the lock.
nonisolated final class ConcurrentRun: @unchecked Sendable {
    private let lock = NSLock()
    private var pingersLeft: Int
    private var latencies: [UInt64] = []
    private var failure: String?
    private var startedAt: UInt64 = 0
    private var pingsEndedAt: UInt64 = 0
    private var bulkBytes = 0
    private var bulkEndedAt: UInt64 = 0

    init(pingers: Int) {
        pingersLeft = pingers
    }

    var firstFailure: String? {
        lock.withLock { failure }
    }

    func begin() {
        lock.withLock { startedAt = Self.now() }
    }

    func ping(_ fd: Int32, client: Int, rounds: Int) {
        var measured: [UInt64] = []
        measured.reserveCapacity(rounds)
        var error: String?
        for _ in 0..<rounds {
            let sentAt = Self.now()
            do {
                try LocalClient.sendPing(fd)
                try LocalClient.expectPong(fd)
            } catch let thrown {
                error = "client \(client) after \(measured.count) round trips: \(thrown)"
                break
            }
            measured.append(Self.now() - sentAt)
        }
        let endedAt = Self.now()
        lock.withLock {
            latencies += measured
            failure = failure ?? error
            pingersLeft -= 1
            pingsEndedAt = max(pingsEndedAt, endedAt)
        }
    }

    // Keeps downloading until the last ping client is done, so the two share the transport throughout.
    func download(_ fd: Int32, key: String, size: Int) {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        var error: String?
        repeat {
            do {
                let received = try RedisClient.get(fd, key: key, buffer: &buffer)
                guard received == size else { throw HarnessFailure(description: "GET returned \(received) of \(size) bytes") }
                total += received
            } catch let thrown {
                error = "bulk client after \(total) bytes: \(thrown)"
                break
            }
        } while lock.withLock({ pingersLeft > 0 })
        let endedAt = Self.now()
        lock.withLock {
            bulkBytes = total
            bulkEndedAt = endedAt
            failure = failure ?? error
        }
    }

    func line(clients: Int, rounds: Int, bulk: Bool) -> String {
        lock.withLock {
            let sorted = latencies.sorted()
            let slow = sorted.filter { $0 > 100_000_000 }.count
            var text = "CONCURRENT clients=\(clients) rounds=\(rounds)"
            text += " p50=\(Self.milliseconds(Self.percentile(sorted, 0.50)))"
            text += " p99=\(Self.milliseconds(Self.percentile(sorted, 0.99)))"
            text += " max=\(Self.milliseconds(sorted.last ?? 0)) over100ms=\(slow)"
            text += " total=\(String(format: "%.3f", Double(pingsEndedAt - startedAt) / 1e9))"
            if bulk {
                let megabytes = Double(bulkBytes) / Double(TunnelHarness.bytesPerMegabyte)
                text += " bulk=\(String(format: "%.1f", megabytes / (Double(bulkEndedAt - startedAt) / 1e9)))"
            }
            return text
        }
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // Nearest rank.
    private static func percentile(_ sorted: [UInt64], _ fraction: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.1f", Double(nanoseconds) / 1e6)
    }
}

nonisolated enum TunnelHarness {
    typealias Opener = @Sendable (HarnessOptions) async throws -> any HarnessTunnel

    static let bytesPerMegabyte = 1 << 20

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
        case "idle":
            await idle(options, open: open)
        case "bulk":
            await bulk(options, open: open)
        case "concurrent":
            await concurrent(options, open: open)
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
        let waitSeconds = options.waitSeconds ?? 75
        var relayingStopped: Duration?
        var idleStopped: Duration?
        while relayingStopped == nil || idleStopped == nil, start.duration(to: clock.now) < .seconds(waitSeconds) {
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

    // The counters are the whole process, so the run with no client is the tunnel's own cost and the
    // runs with clients add each relay's.
    static func idle(_ options: HarnessOptions, open: Opener) async -> Never {
        let waitSeconds = options.waitSeconds ?? 30
        let tunnel = await openOrFinish(options, open: open)
        var sockets: [Int32] = []
        do {
            for _ in 0..<options.count {
                let fd = try LocalClient.open(port: tunnel.localPort)
                sockets.append(fd)
            }
        } catch {
            Output.finish("ERROR relay: client \(sockets.count + 1) of \(options.count): \(error)", code: 1)
        }
        pingEach(sockets, when: "before the wait")

        let clock = ContinuousClock()
        let start = clock.now
        let wakeupsAtStart = ProcessCounters.wakeups()
        let cpuAtStart = cpuSeconds()
        try? await Task.sleep(for: .seconds(waitSeconds))
        let wakeupsAtEnd = ProcessCounters.wakeups()
        let cpu = cpuSeconds() - cpuAtStart
        let elapsed = interval(start.duration(to: clock.now))
        let threads = ProcessCounters.threads()

        pingEach(sockets, when: "after the wait")
        sockets.forEach { Darwin.close($0) }
        tunnel.close()
        var wakeups = "n/a"
        var perSecond = "n/a"
        if let wakeupsAtStart, let wakeupsAtEnd {
            wakeups = "\(wakeupsAtEnd - wakeupsAtStart)"
            perSecond = String(format: "%.2f", Double(wakeupsAtEnd - wakeupsAtStart) / elapsed)
        }
        Output.finish(
            "IDLE clients=\(options.count) seconds=\(waitSeconds) wakeups=\(wakeups) per_second=\(perSecond)"
                + " cpu=\(String(format: "%.2f", cpu)) threads=\(threads.map { "\($0)" } ?? "n/a")",
            code: 0
        )
    }

    static func bulk(_ options: HarnessOptions, open: Opener) async -> Never {
        let megabytes = options.sizeMegabytes ?? 64
        let size = megabytes * bytesPerMegabyte
        let key = "tp-relay-bulk"
        let tunnel = await openOrFinish(options, open: open)
        let upload: Duration
        let download: Duration
        do {
            let fd = try LocalClient.open(port: tunnel.localPort, timeoutSeconds: LocalClient.bulkTimeoutSeconds)
            let value = [UInt8](repeating: UInt8(ascii: "a"), count: size)
            let clock = ContinuousClock()
            let uploadStart = clock.now
            try RedisClient.set(fd, key: key, value: value)
            upload = uploadStart.duration(to: clock.now)

            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            let downloadStart = clock.now
            let received = try RedisClient.get(fd, key: key, buffer: &buffer)
            download = downloadStart.duration(to: clock.now)
            guard received == size else { throw HarnessFailure(description: "GET returned \(received) of \(size) bytes") }

            try RedisClient.delete(fd, key: key)
            Darwin.close(fd)
        } catch {
            Output.finish("ERROR relay: bulk: \(error)", code: 1)
        }
        tunnel.close()
        let uploadSeconds = interval(upload)
        let downloadSeconds = interval(download)
        Output.finish(
            "BULK size=\(megabytes)MB upload=\(String(format: "%.1f", Double(megabytes) / uploadSeconds))"
                + " download=\(String(format: "%.1f", Double(megabytes) / downloadSeconds))"
                + " upload_s=\(String(format: "%.3f", uploadSeconds)) download_s=\(String(format: "%.3f", downloadSeconds))",
            code: 0
        )
    }

    // Every client connects, and the bulk value is stored, before the gate starts them all at once.
    static func concurrent(_ options: HarnessOptions, open: Opener) async -> Never {
        let key = "tp-relay-concurrent"
        let rounds = options.rounds
        let tunnel = await openOrFinish(options, open: open)
        var pingers: [Int32] = []
        var bulkClient: (fd: Int32, size: Int)?
        do {
            for _ in 0..<options.count {
                let fd = try LocalClient.open(port: tunnel.localPort)
                pingers.append(fd)
            }
            if let megabytes = options.sizeMegabytes {
                let fd = try LocalClient.open(port: tunnel.localPort, timeoutSeconds: LocalClient.bulkTimeoutSeconds)
                let size = megabytes * bytesPerMegabyte
                try RedisClient.set(fd, key: key, value: [UInt8](repeating: UInt8(ascii: "a"), count: size))
                bulkClient = (fd, size)
            }
        } catch {
            Output.finish("ERROR relay: \(error)", code: 1)
        }

        let run = ConcurrentRun(pingers: pingers.count)
        let gate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for (index, fd) in pingers.enumerated() {
            group.enter()
            let thread = Thread {
                gate.wait()
                run.ping(fd, client: index + 1, rounds: rounds)
                group.leave()
            }
            thread.start()
        }
        if let bulkClient {
            group.enter()
            let thread = Thread {
                gate.wait()
                run.download(bulkClient.fd, key: key, size: bulkClient.size)
                group.leave()
            }
            thread.start()
        }
        run.begin()
        for _ in 0..<(pingers.count + (bulkClient == nil ? 0 : 1)) {
            gate.signal()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if let failure = run.firstFailure {
            Output.finish("ERROR relay: \(failure)", code: 1)
        }
        if let bulkClient {
            try? RedisClient.delete(bulkClient.fd, key: key)
            Darwin.close(bulkClient.fd)
        }
        pingers.forEach { Darwin.close($0) }
        tunnel.close()
        Output.finish(run.line(clients: options.count, rounds: rounds, bulk: bulkClient != nil), code: 0)
    }

    private static func pingEach(_ sockets: [Int32], when: String) {
        for (index, fd) in sockets.enumerated() {
            do {
                try LocalClient.sendPing(fd)
                try LocalClient.expectPong(fd)
            } catch {
                Output.finish("ERROR relay: client \(index + 1) of \(sockets.count) \(when): \(error)", code: 1)
            }
        }
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
        return String(format: "%.1f", interval(duration))
    }

    private static func interval(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}
