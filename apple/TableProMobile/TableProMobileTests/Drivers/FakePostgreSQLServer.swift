import Darwin
import Foundation
import os

// A loopback PostgreSQL server for one plaintext session: it refuses SSL and GSS encryption, accepts any startup without
// a password, and answers a statement through the simple or the extended protocol with its scripted reply, or with an
// empty completion. It keeps the transaction status a BEGIN, START TRANSACTION, COMMIT or ROLLBACK leaves, and answers a
// cancel request on a second connection without acting on it.
final class FakePostgreSQLServer: @unchecked Sendable {
    struct SetupFailure: Error {}

    enum Reply: Sendable {
        // One text column `n`, its values `row 0`, `row 1` and on.
        case rows(Int)
        // An ErrorResponse after `rowsFirst` rows.
        case failure(sqlState: String, message: String, rowsFirst: Int = 0)
    }

    struct Session: Sendable {
        var startedUp = false
        // Every statement in the order it arrived, as a simple Query or a Parse.
        var queries: [String] = []
        var extendedQueries: [String] = []
        var terminated = false
    }

    private static let protocolVersion: UInt32 = 196_608
    private static let sslRequest: UInt32 = 80_877_103
    private static let gssEncryptionRequest: UInt32 = 80_877_104
    private static let cancelRequest: UInt32 = 80_877_102
    private static let pollMilliseconds: Int32 = 10_000
    private static let cancelPollMilliseconds: Int32 = 100
    private static let textOid: UInt32 = 25
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
    private let replies: [String: Reply]
    private let sessionEnded = OSAllocatedUnfairLock(initialState: false)

    init(replies: [String: Reply] = [:]) throws {
        self.replies = replies
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
        guard let client = acceptClient(within: Self.pollMilliseconds) else { return session }
        defer { Darwin.close(client) }
        // Stopped and waited for before the session returns, so it never polls a listener the test has closed.
        let cancels = DispatchGroup()
        cancels.enter()
        DispatchQueue(label: "com.TablePro.tests.fake-postgresql.cancel").async {
            self.answerCancels()
            cancels.leave()
        }
        defer {
            sessionEnded.withLock { $0 = true }
            cancels.wait()
        }
        guard startUp(client) else { return session }
        session.startedUp = true

        var conversation = Conversation()
        while let type = receive(client, 1)?.first, let body = receiveBody(client) {
            guard type != UInt8(ascii: "X") else {
                session.terminated = true
                return session
            }
            guard let reply = conversation.answer(type, body, server: self, session: &session),
                  reply.isEmpty || send(client, reply) else { return session }
        }
        return session
    }

    // libpq's PQcancel opens a connection of its own, sends the request and waits for the server to close it.
    private func answerCancels() {
        while !sessionEnded.withLock({ $0 }) {
            var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, Self.cancelPollMilliseconds)
            guard ready >= 0, pollFD.revents & Int16(POLLNVAL) == 0 else { return }
            guard ready > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            _ = receiveBody(connection)
            Darwin.close(connection)
        }
    }

    // What one session has said so far: the transaction status and, in the extended protocol, the statement parsed and
    // whether an error has the rest skipped up to the Sync.
    private struct Conversation {
        var status = UInt8(ascii: "I")
        var parsed = ""
        var skippingToSync = false

        mutating func answer(_ type: UInt8, _ body: [UInt8], server: FakePostgreSQLServer, session: inout Session) -> [UInt8]? {
            switch type {
            case UInt8(ascii: "Q"):
                let query = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                session.queries.append(query)
                return run(query, server: server, describes: true) + FakePostgreSQLServer.message("Z", [status])
            case UInt8(ascii: "P"):
                let fields = body.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
                parsed = fields.count > 1 ? String(decoding: fields[1], as: UTF8.self) : ""
                session.queries.append(parsed)
                session.extendedQueries.append(parsed)
                return FakePostgreSQLServer.message("1", [])
            case UInt8(ascii: "B"):
                return skippingToSync ? [] : FakePostgreSQLServer.message("2", [])
            case UInt8(ascii: "D"):
                return skippingToSync ? [] : FakePostgreSQLServer.rowDescription
            case UInt8(ascii: "E"):
                guard !skippingToSync else { return [] }
                if case .failure? = server.replies[parsed] { skippingToSync = true }
                return run(parsed, server: server, describes: false)
            case UInt8(ascii: "S"):
                skippingToSync = false
                return FakePostgreSQLServer.message("Z", [status])
            case UInt8(ascii: "H"):
                return []
            default:
                return nil
            }
        }

        private mutating func run(_ query: String, server: FakePostgreSQLServer, describes: Bool) -> [UInt8] {
            let head = query.trimmingCharacters(in: .whitespaces).uppercased()
            switch server.replies[query] {
            case .rows(let count)?:
                return (describes ? FakePostgreSQLServer.rowDescription : []) + FakePostgreSQLServer.dataRows(count)
                    + FakePostgreSQLServer.message("C", Array("SELECT \(count)".utf8) + [0])
            case .failure(let sqlState, let message, let rowsFirst)?:
                if status == UInt8(ascii: "T") { status = UInt8(ascii: "E") }
                let header = rowsFirst > 0 && describes ? FakePostgreSQLServer.rowDescription : []
                return header + FakePostgreSQLServer.dataRows(rowsFirst) + FakePostgreSQLServer.errorResponse(sqlState, message)
            case nil:
                if head.hasPrefix("BEGIN") || head.hasPrefix("START TRANSACTION") {
                    status = UInt8(ascii: "T")
                } else if ["COMMIT", "ROLLBACK", "END", "ABORT"].contains(where: { head.hasPrefix($0) }) {
                    status = UInt8(ascii: "I")
                }
                return FakePostgreSQLServer.message("C", Array("SELECT 0".utf8) + [0])
            }
        }
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
            reply += Self.message("Z", [UInt8(ascii: "I")])
            return send(client, reply)
        }
        return false
    }

    // A text column `n`, from no table.
    private static var rowDescription: [UInt8] {
        message(
            "T",
            bytes16(1) + Array("n".utf8) + [0] + bytes(UInt32(0)) + bytes16(0) + bytes(textOid) + bytes16(0xFFFF)
                + bytes(UInt32.max) + bytes16(0)
        )
    }

    private static func dataRows(_ count: Int) -> [UInt8] {
        var rows: [UInt8] = []
        for index in 0..<count {
            let value = Array("row \(index)".utf8)
            rows += message("D", bytes16(1) + bytes(UInt32(value.count)) + value)
        }
        return rows
    }

    private static func errorResponse(_ sqlState: String, _ text: String) -> [UInt8] {
        let fields: [(Character, String)] = [("S", "ERROR"), ("V", "ERROR"), ("C", sqlState), ("M", text)]
        return message("E", fields.flatMap { [$0.0.asciiValue ?? 0] + Array($0.1.utf8) + [0] } + [0])
    }

    private static func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        [type.asciiValue ?? 0] + bytes(UInt32(body.count + 4)) + body
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func bytes16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
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

    private func acceptClient(within milliseconds: Int32) -> Int32? {
        var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, milliseconds) > 0 else { return nil }
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
