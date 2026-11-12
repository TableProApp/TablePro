//
//  LibPQScriptedServer.swift
//  PostgreSQLDriverTests
//

import Darwin
import Foundation

// A loopback PostgreSQL server for one plaintext session. It refuses SSL and GSS encryption, accepts any startup
// without a password, records each simple query and each statement the extended protocol parses, runs `onQuery` before
// it answers, and reports the transaction status `status` picks from the query and the ones before it. A simple query
// or a parsed statement gets what `answer` returns for it; without one, each statement of a simple query gets an empty
// completion, except that a statement holding `failingStatement` gets an error and the ones after it nothing. Cancel
// requests arrive on connections of their own: each is counted, and a statement waiting for one then fails as a
// cancelled statement does.
final class LibPQScriptedServer: @unchecked Sendable {
    struct SetupFailure: Error {}

    struct Column: Sendable {
        let name: String
        var table: UInt32 = 0
        var attribute: Int16 = 0
        var type: UInt32 = 25
    }

    struct Failure: Sendable {
        let sqlState: String
        let message: String
    }

    struct Answer: Sendable {
        var columns: [Column] = []
        var rows: [[String?]] = []
        // After the rows, wait for a cancel request and fail with 57014. A statement nobody cancels completes.
        var waitsForCancel = false
        var failure: Failure?
    }

    static let idle = UInt8(ascii: "I")
    static let inTransaction = UInt8(ascii: "T")
    static let failedTransaction = UInt8(ascii: "E")

    private static let protocolVersion: UInt32 = 196_608
    private static let sslRequest: UInt32 = 80_877_103
    private static let gssEncryptionRequest: UInt32 = 80_877_104
    private static let cancelRequest: UInt32 = 80_877_102
    private static let pollMilliseconds: Int32 = 10_000
    private static let cancelWait: DispatchTimeInterval = .seconds(5)
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
    private let answer: @Sendable (String) -> Answer?
    private let cancelArrived = DispatchSemaphore(value: 0)
    private let failingStatement: String?
    private let lock = NSLock()
    private var received: [String] = []
    private var bindings: [[String?]] = []
    private var cancels = 0
    private var isClosed = false

    var queries: [String] {
        lock.withLock { received }
    }

    // Each Bind's parameters as text, nil for a null.
    var boundParameters: [[String?]] {
        lock.withLock { bindings }
    }

    var cancelRequests: Int {
        lock.withLock { cancels }
    }

    init(
        status: @escaping @Sendable (_ query: String, _ earlier: [String]) -> UInt8 = { _, _ in LibPQScriptedServer.idle },
        onQuery: @escaping @Sendable (String) -> Void = { _ in },
        answer: @escaping @Sendable (String) -> Answer? = { _ in nil },
        failingStatement: String? = nil
    ) throws {
        self.status = status
        self.onQuery = onQuery
        self.answer = answer
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
        lock.withLock { isClosed = true }
        Darwin.close(listener)
    }

    private struct Statement {
        let query: String
        let earlier: [String]
        let answer: Answer
    }

    private func runSession() {
        guard let client = acceptClient() else { return }
        defer { Darwin.close(client) }
        DispatchQueue(label: "com.TablePro.tests.scripted-postgresql.cancel").async { self.acceptCancelRequests() }
        guard startUp(client) else { return }

        var statement: Statement?
        var failed = false
        while let type = receive(client, 1)?.first, let body = receiveBody(client) {
            var reply: [UInt8] = []
            switch type {
            case UInt8(ascii: "Q"):
                let query = Self.cString(body, from: 0).text
                let earlier = record(query)
                onQuery(query)
                var simpleFailed = false
                if let scripted = answer(query) {
                    if scripted.failure == nil, !scripted.columns.isEmpty {
                        guard send(client, Self.rowDescription(scripted.columns)) else { return }
                    }
                    guard execute(scripted, on: client, failed: &simpleFailed) else { return }
                } else {
                    reply = answers(to: query)
                }
                var state = status(query, earlier)
                if simpleFailed, state == Self.inTransaction { state = Self.failedTransaction }
                reply += Self.message("Z", [state])
            case UInt8(ascii: "P"):
                let query = Self.cString(body, from: Self.cString(body, from: 0).next).text
                let earlier = record(query)
                onQuery(query)
                statement = Statement(query: query, earlier: earlier, answer: answer(query) ?? Answer())
                if !failed { reply = Self.message("1", []) }
            case UInt8(ascii: "B"):
                lock.withLock { bindings.append(Self.parameters(ofBind: body)) }
                if !failed { reply = Self.message("2", []) }
            case UInt8(ascii: "D"):
                guard !failed, let statement else { break }
                let columns = statement.answer.failure == nil ? statement.answer.columns : []
                reply = columns.isEmpty ? Self.message("n", []) : Self.rowDescription(columns)
            case UInt8(ascii: "E"):
                guard !failed, let statement else { break }
                guard execute(statement.answer, on: client, failed: &failed) else { return }
            case UInt8(ascii: "S"):
                var state = statement.map { status($0.query, $0.earlier) } ?? Self.idle
                if failed, state == Self.inTransaction { state = Self.failedTransaction }
                reply = Self.message("Z", [state])
                statement = nil
                failed = false
            case UInt8(ascii: "H"):
                break
            case UInt8(ascii: "C"):
                if !failed { reply = Self.message("3", []) }
            default:
                return
            }
            guard reply.isEmpty || send(client, reply) else { return }
        }
    }

    private func record(_ query: String) -> [String] {
        lock.withLock { () -> [String] in
            defer { received.append(query) }
            return received
        }
    }

    // The rows go out before any wait, as a server streams them, so the client can stop and cancel while it waits.
    private func execute(_ answer: Answer, on client: Int32, failed: inout Bool) -> Bool {
        if let failure = answer.failure {
            failed = true
            return send(client, Self.errorResponse(failure))
        }
        guard send(client, answer.rows.flatMap(Self.dataRow)) else { return false }
        if answer.waitsForCancel, cancelArrived.wait(timeout: .now() + Self.cancelWait) == .success {
            failed = true
            return send(client, Self.errorResponse(Failure(
                sqlState: "57014", message: "canceling statement due to user request"
            )))
        }
        return send(client, Self.message("C", Array("SELECT \(answer.rows.count)".utf8) + [0]))
    }

    private func acceptCancelRequests() {
        while !lock.withLock({ isClosed }) {
            var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 100) >= 0 else { return }
            guard pollFD.revents & Int16(POLLIN) != 0, !lock.withLock({ isClosed }) else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            if let packet = receiveBody(client), packet.count == 12, Self.uint32(packet.prefix(4)) == Self.cancelRequest {
                lock.withLock { cancels += 1 }
                cancelArrived.signal()
            }
            Darwin.close(client)
        }
    }

    private func answers(to query: String) -> [UInt8] {
        let statements = Self.statements(in: query)
        var reply: [UInt8] = []
        for statement in statements.isEmpty ? [query] : statements {
            if let failingStatement, statement.contains(failingStatement) {
                return reply + Self.errorResponse(Failure(sqlState: "42501", message: "permission denied"))
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

    private static func rowDescription(_ columns: [Column]) -> [UInt8] {
        var body = bytes(UInt16(columns.count))
        for column in columns {
            body += Array(column.name.utf8) + [0]
            body += bytes(column.table) + bytes(UInt16(bitPattern: column.attribute)) + bytes(column.type)
            body += bytes(UInt16(bitPattern: -1)) + bytes(UInt32(bitPattern: -1)) + bytes(UInt16(0))
        }
        return message("T", body)
    }

    private static func dataRow(_ row: [String?]) -> [UInt8] {
        var body = bytes(UInt16(row.count))
        for value in row {
            guard let value else {
                body += bytes(UInt32(bitPattern: -1))
                continue
            }
            body += bytes(UInt32(value.utf8.count)) + Array(value.utf8)
        }
        return message("D", body)
    }

    private static func errorResponse(_ failure: Failure) -> [UInt8] {
        let fields: [(UInt8, String)] = [
            (UInt8(ascii: "S"), "ERROR"),
            (UInt8(ascii: "V"), "ERROR"),
            (UInt8(ascii: "C"), failure.sqlState),
            (UInt8(ascii: "M"), failure.message),
        ]
        var body: [UInt8] = []
        for (code, value) in fields {
            body += [code] + Array(value.utf8) + [0]
        }
        return message("E", body + [0])
    }

    // Portal and statement names, the format codes, then each parameter as a length (-1 for null) and its bytes.
    private static func parameters(ofBind body: [UInt8]) -> [String?] {
        let afterPortal = cString(body, from: 0).next
        var offset = cString(body, from: afterPortal).next
        guard let formats = int16(body, at: offset) else { return [] }
        offset += 2 + 2 * Int(formats)
        guard let count = int16(body, at: offset) else { return [] }
        offset += 2
        var values: [String?] = []
        for _ in 0..<max(Int(count), 0) {
            guard offset + 4 <= body.count else { return values }
            let length = Int32(bitPattern: uint32(body[offset..<offset + 4]))
            offset += 4
            guard length >= 0, offset + Int(length) <= body.count else {
                values.append(nil)
                continue
            }
            values.append(String(bytes: body[offset..<offset + Int(length)], encoding: .utf8))
            offset += Int(length)
        }
        return values
    }

    private static func cString(_ body: [UInt8], from start: Int) -> (text: String, next: Int) {
        guard start < body.count else { return ("", body.count) }
        let end = body[start...].firstIndex(of: 0) ?? body.count
        return (String(bytes: body[start..<end], encoding: .utf8) ?? "", min(end + 1, body.count))
    }

    private static func int16(_ body: [UInt8], at offset: Int) -> Int16? {
        guard offset + 2 <= body.count else { return nil }
        return Int16(bitPattern: UInt16(body[offset]) << 8 | UInt16(body[offset + 1]))
    }

    private static func message(_ type: Character, _ body: [UInt8]) -> [UInt8] {
        [type.asciiValue ?? 0] + bytes(UInt32(body.count + 4)) + body
    }


    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func bytes(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
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
