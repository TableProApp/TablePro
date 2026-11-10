import Darwin
import Foundation

// A loopback PostgreSQL server for one plaintext session: it refuses SSL and GSS encryption, accepts any startup without
// a password, and answers every simple query with an empty completion.
final class FakePostgreSQLServer: @unchecked Sendable {
    struct SetupFailure: Error {}

    struct Session: Sendable {
        var startedUp = false
        var queries: [String] = []
        var terminated = false
    }

    private static let protocolVersion: UInt32 = 196_608
    private static let sslRequest: UInt32 = 80_877_103
    private static let gssEncryptionRequest: UInt32 = 80_877_104
    private static let pollMilliseconds: Int32 = 10_000
    private static let parameters: [(String, String)] = [
        ("server_version", "16.4"),
        ("server_encoding", "UTF8"),
        ("client_encoding", "UTF8"),
        ("standard_conforming_strings", "on"),
        ("DateStyle", "ISO, MDY"),
        ("integer_datetimes", "on"),
        ("TimeZone", "UTC"),
    ]

    let port: Int
    private let listener: Int32

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SetupFailure() }
        var option: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &option, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(socketFD, 4) == 0 else {
            Darwin.close(socketFD)
            throw SetupFailure()
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard named == 0 else {
            Darwin.close(socketFD)
            throw SetupFailure()
        }
        listener = socketFD
        port = Int(boundAddress.sin_port.bigEndian)
    }

    func close() {
        Darwin.close(listener)
    }

    func serveOneSession() async -> Session {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.TablePro.tests.fake-postgresql").async {
                continuation.resume(returning: self.runSession())
            }
        }
    }

    private func runSession() -> Session {
        var session = Session()
        guard let client = acceptClient() else { return session }
        defer { Darwin.close(client) }
        guard startUp(client) else { return session }
        session.startedUp = true

        while let type = receive(client, 1)?.first, let body = receiveBody(client) {
            switch type {
            case UInt8(ascii: "Q"):
                session.queries.append(String(decoding: body.prefix { $0 != 0 }, as: UTF8.self))
                guard send(client, Self.message("C", Array("SELECT 0".utf8) + [0])),
                      send(client, Self.readyForQuery) else { return session }
            case UInt8(ascii: "X"):
                session.terminated = true
                return session
            default:
                return session
            }
        }
        return session
    }

    // The client may ask for SSL or GSS encryption first; each gets "N" and the real startup follows.
    private func startUp(_ client: Int32) -> Bool {
        while let packet = receiveBody(client), packet.count >= 4 {
            let code = Self.uint32(packet.prefix(4))
            if code == Self.sslRequest || code == Self.gssEncryptionRequest {
                guard send(client, [UInt8(ascii: "N")]) else { return false }
                continue
            }
            guard code == Self.protocolVersion else { return false }
            var reply = Self.message("R", Self.bytes(UInt32(0)))
            for (name, value) in Self.parameters {
                reply += Self.message("S", Array(name.utf8) + [0] + Array(value.utf8) + [0])
            }
            reply += Self.message("K", Self.bytes(UInt32(4_242)) + Self.bytes(UInt32(7_777)))
            reply += Self.readyForQuery
            return send(client, reply)
        }
        return false
    }

    private static var readyForQuery: [UInt8] {
        message("Z", [UInt8(ascii: "I")])
    }

    private static func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        [type.asciiValue ?? 0] + bytes(UInt32(body.count + 4)) + body
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func uint32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    // A length that counts its own four bytes, then that many minus four.
    private func receiveBody(_ client: Int32) -> [UInt8]? {
        guard let header = receive(client, 4) else { return nil }
        let length = Int(Self.uint32(header))
        guard length >= 4 else { return nil }
        return length == 4 ? [] : receive(client, length - 4)
    }

    private func acceptClient() -> Int32? {
        var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, Self.pollMilliseconds) > 0 else { return nil }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return client
    }

    private func receive(_ client: Int32, _ count: Int) -> [UInt8]? {
        var bytes: [UInt8] = []
        while bytes.count < count {
            var pollFD = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, Self.pollMilliseconds) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: count - bytes.count)
            let received = recv(client, &chunk, chunk.count, 0)
            guard received > 0 else { return nil }
            bytes += chunk.prefix(received)
        }
        return bytes
    }

    private func send(_ client: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes[offset...].withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }
}
