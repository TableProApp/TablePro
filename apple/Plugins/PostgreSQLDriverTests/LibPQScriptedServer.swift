//
//  LibPQScriptedServer.swift
//  PostgreSQLDriverTests
//

import Darwin
import Foundation

// A loopback PostgreSQL server for one plaintext session. It refuses SSL and GSS encryption, accepts any startup
// without a password, records each simple query, runs `onQuery` before it answers, and answers each statement in it
// with an empty completion, then the transaction status `status` picks from the query and the ones before it. A
// statement holding `failingStatement` gets an error instead, and the statements after it in that query get nothing.
final class LibPQScriptedServer: @unchecked Sendable {
    struct SetupFailure: Error {}

    static let idle = UInt8(ascii: "I")
    static let inTransaction = UInt8(ascii: "T")

    private static let protocolVersion: UInt32 = 196_608
    private static let sslRequest: UInt32 = 80_877_103
    private static let gssEncryptionRequest: UInt32 = 80_877_104
    private static let pollMilliseconds: Int32 = 10_000
    private static let parameters: [(String, String)] = [
        ("server_version", "17.4"),
        ("server_encoding", "UTF8"),
        ("client_encoding", "UTF8"),
        ("standard_conforming_strings", "on"),
        ("DateStyle", "ISO, MDY"),
        ("integer_datetimes", "on"),
        ("TimeZone", "UTC"),
    ]

    let port: Int
    private let listener: Int32
    private let status: @Sendable (_ query: String, _ earlier: [String]) -> UInt8
    private let onQuery: @Sendable (String) -> Void
    private let failingStatement: String?
    private let lock = NSLock()
    private var received: [String] = []

    var queries: [String] {
        lock.withLock { received }
    }

    init(
        status: @escaping @Sendable (_ query: String, _ earlier: [String]) -> UInt8 = { _, _ in LibPQScriptedServer.idle },
        onQuery: @escaping @Sendable (String) -> Void = { _ in },
        failingStatement: String? = nil
    ) throws {
        self.status = status
        self.onQuery = onQuery
        self.failingStatement = failingStatement
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw SetupFailure() }
        var option: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &option, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        guard bound == 0, Darwin.listen(socketFD, 4) == 0, named == 0 else {
            Darwin.close(socketFD)
            throw SetupFailure()
        }
        listener = socketFD
        port = Int(boundAddress.sin_port.bigEndian)
    }

    func start() {
        DispatchQueue(label: "com.TablePro.tests.scripted-postgresql").async { self.runSession() }
    }

    func close() {
        Darwin.close(listener)
    }

    private func runSession() {
        guard let client = acceptClient() else { return }
        defer { Darwin.close(client) }
        guard startUp(client) else { return }

        while let type = receive(client, 1)?.first, type == UInt8(ascii: "Q"), let body = receiveBody(client) {
            let query = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            let earlier = lock.withLock { () -> [String] in
                defer { received.append(query) }
                return received
            }
            onQuery(query)
            let reply = answers(to: query) + Self.message("Z", [status(query, earlier)])
            guard send(client, reply) else { return }
        }
    }

    private func answers(to query: String) -> [UInt8] {
        let statements = Self.statements(in: query)
        var reply: [UInt8] = []
        for statement in statements.isEmpty ? [query] : statements {
            if let failingStatement, statement.contains(failingStatement) {
                return reply + Self.errorResponse(sqlState: "42501", text: "permission denied")
            }
            reply += Self.message("C", Array("SELECT 0".utf8) + [0])
        }
        return reply
    }

    // Splits on each `;` outside a quoted literal or identifier, which is enough for the statements the driver sends.
    private static func statements(in query: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var quote: Character?
        for character in query {
            if character == ";", quote == nil {
                statements.append(current)
                current = ""
                continue
            }
            if character == quote {
                quote = nil
            } else if quote == nil, character == "'" || character == "\"" {
                quote = character
            }
            current.append(character)
        }
        statements.append(current)
        return statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

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
            reply += Self.message("Z", [Self.idle])
            return send(client, reply)
        }
        return false
    }

    private static func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        [type.asciiValue ?? 0] + bytes(UInt32(body.count + 4)) + body
    }

    private static func errorResponse(sqlState: String, text: String) -> [UInt8] {
        var body: [UInt8] = []
        for (field, value) in [("S", "ERROR"), ("V", "ERROR"), ("C", sqlState), ("M", text)] {
            body += Array(field.utf8) + Array(value.utf8) + [0]
        }
        return message("E", body + [0])
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
            let read = recv(client, &chunk, chunk.count, 0)
            guard read > 0 else { return nil }
            bytes += chunk.prefix(read)
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
