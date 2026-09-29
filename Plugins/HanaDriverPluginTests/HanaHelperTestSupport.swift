import Darwin
import Foundation

enum HanaTestSocketError: Error {
    case failed(String, Int32)
}

final class HanaSilentServer: @unchecked Sendable {
    let port: Int

    private let listener: Int32
    private let lock = NSLock()
    private var accepted: [Int32] = []
    private var isStopped = false

    init() throws {
        let listener = try HanaLoopbackSocket.bound()
        guard Darwin.listen(listener, 8) == 0 else {
            let failure = errno
            Darwin.close(listener)
            throw HanaTestSocketError.failed("listen", failure)
        }
        self.listener = listener
        port = try HanaLoopbackSocket.port(of: listener)
    }

    deinit {
        stop()
    }

    func awaitConnection(within seconds: TimeInterval) -> Bool {
        var request = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&request, 1, Int32(seconds * 1_000)) > 0 else { return false }
        return lock.withLock { () -> Bool in
            guard !isStopped else { return false }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return false }
            accepted.append(connection)
            return true
        }
    }

    func stop() {
        let open = lock.withLock { () -> [Int32] in
            guard !isStopped else { return [] }
            isStopped = true
            let open = accepted + [listener]
            accepted.removeAll()
            return open
        }
        open.forEach { Darwin.close($0) }
    }
}

enum HanaLoopbackSocket {
    static func closedPort() throws -> Int {
        let socket = try bound()
        defer { Darwin.close(socket) }
        return try port(of: socket)
    }

    static func bound() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HanaTestSocketError.failed("socket", errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw HanaTestSocketError.failed("bind", failure)
        }
        return descriptor
    }

    static func port(of descriptor: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else { throw HanaTestSocketError.failed("getsockname", errno) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

final class HanaBlockingCall: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var outcome: Result<Data, any Error>?

    init(_ work: @escaping @Sendable () throws -> Data) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try work() }
            self.lock.withLock { self.outcome = outcome }
            self.finished.signal()
        }
    }

    var hasFinished: Bool {
        lock.withLock { outcome != nil }
    }

    func outcome(within seconds: TimeInterval) -> Result<Data, any Error>? {
        guard finished.wait(timeout: .now() + seconds) == .success else { return nil }
        finished.signal()
        return lock.withLock { outcome }
    }
}

enum HanaProcessProbe {
    static func isRunning(_ processIdentifier: pid_t) -> Bool {
        kill(processIdentifier, 0) == 0 || errno != ESRCH
    }

    static func waitForExit(of processIdentifier: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard isRunning(processIdentifier) else { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !isRunning(processIdentifier)
    }
}

final class HanaStandInFolder: @unchecked Sendable {
    let url: URL

    init(named prefix: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(named name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func script(_ body: String) throws -> URL {
        let script = file(named: "helper-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

enum HanaStandInFrame {
    static let greetingBody = #"{"protocol":1,"forcedSeverGraceSeconds":30}"#

    static func greeting(_ body: String = greetingBody) -> String {
        frame(id: HanaHelperHandshake.frameID, code: 0, body: body)
    }

    static func frame(id: UInt64, code: UInt8, body: String) -> String {
        let header = HanaHelperFrameHeader(bodyLength: UInt32(body.utf8.count), id: id, code: code)
        return "/usr/bin/printf '\(escaped(header.encoded))\(body)'"
    }

    static func header(bodyLength: UInt32, id: UInt64, code: UInt8) -> String {
        let header = HanaHelperFrameHeader(bodyLength: bodyLength, id: id, code: code)
        return "/usr/bin/printf '\(escaped(header.encoded))'"
    }

    static func absorbInput(into file: URL? = nil) -> String {
        "exec /bin/cat 3>&1 > '\(file?.path ?? "/dev/null")'"
    }

    private static func escaped(_ bytes: Data) -> String {
        bytes.map { String(format: "\\%03o", UInt32($0)) }.joined()
    }
}

enum HanaFileProbe {
    static func byteCount(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func waitForBytes(at url: URL, reaching count: Int, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard byteCount(at: url) < count else { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return byteCount(at: url) >= count
    }

    static func processIdentifier(recordedAt url: URL, within seconds: TimeInterval) -> pid_t? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let recorded = recordedProcessIdentifier(at: url) {
                return recorded
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return recordedProcessIdentifier(at: url)
    }

    private static func recordedProcessIdentifier(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum HanaMemoryProbe {
    static var peakResidentByteCount: Int {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return usage.ru_maxrss
    }
}

final class HanaRunningCodeChecks: @unchecked Sendable {
    struct Request: Equatable {
        let processIdentifier: pid_t
        let requirement: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private let failure: HanaBridgeFailure?

    init(failingWith failure: HanaBridgeFailure? = nil) {
        self.failure = failure
    }

    var requests: [Request] {
        lock.withLock { recorded }
    }

    var record: HanaHelperTrust.RunningCodeCheck {
        { [self] processIdentifier, requirement in
            lock.withLock { recorded.append(Request(processIdentifier: processIdentifier, requirement: requirement)) }
            if let failure {
                throw failure
            }
        }
    }
}
