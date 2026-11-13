import CRedis
import Darwin
import Foundation
import os
import TableProTLSTestFixtures

// Loopback sessions that accept any login. With a certificate it upgrades after the client's SSL
// request; with `asksForCleartext` it answers the login with a switch to mysql_clear_password, as RDS
// does; with `asksForFullSHA2Auth` it switches to caching_sha2_password and asks for full authentication,
// which a client sends as the typed password once it thinks the session is secure; with `breaksHandshake`
// it answers the SSL request with bytes that are not TLS. A query starting with `holdsQueriesStarting` waits
// up to `holdSeconds` for `KILL QUERY <its session id>` from another session, then fails with 1317 as a killed
// statement does, or with `killedQueriesComplete` succeeds as one that finished before the kill landed. Unkilled,
// or after `release`, it succeeds. A query starting with `streamsRowsStarting` returns `streamedRows` one-column rows,
// cut by a kill for its session with 1317. A cleartext password passed to `refuse` is answered with 1045, as an expired
// token is. A query in `failures` is answered with its error, after its rows when it has any. Replies carry
// SERVER_STATUS_IN_TRANS from a BEGIN or START TRANSACTION to the COMMIT or ROLLBACK that ends it.
final class FakeMySQLServer: @unchecked Sendable {
    struct SetupFailure: Error {}

    struct Failure: Sendable {
        let code: UInt16
        let sqlState: String
        let message: String
        var rowsFirst: Int?

        // ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION.
        static func readOnlyRefusal(rowsFirst: Int? = nil) -> Failure {
            Failure(
                code: 1_792, sqlState: "25006", message: "Cannot execute statement in a READ ONLY transaction.",
                rowsFirst: rowsFirst
            )
        }
    }

    struct Identity {
        let certificate: String
        let key: String

        static let localhost = Identity(certificate: TLSTestFixtures.serverCertificate, key: TLSTestFixtures.serverKey)
        static let rogue = Identity(certificate: TLSTestFixtures.rogueCertificate, key: TLSTestFixtures.rogueKey)
    }

    struct Session: Sendable {
        var plaintext: [UInt8] = []
        var askedForTLS = false
        var encrypted = false
        var sawLogin = false
        var cleartextPassword: String?
        var fullAuthAnswer: [UInt8]?
        var loggedIn = false
        var queries: [String] = []
        var quit = false
        var connectionId: UInt32 = 0
        var streamedRowsSent = 0
        var streamWasKilled = false

        func sawInPlaintext(_ secret: String) -> Bool {
            let needle = Array(secret.utf8)
            guard !needle.isEmpty, plaintext.count >= needle.count else { return false }
            return (0...(plaintext.count - needle.count)).contains { start in
                plaintext[start..<(start + needle.count)].elementsEqual(needle)
            }
        }
    }

    private struct Packet {
        let sequence: UInt8
        let payload: [UInt8]
    }

    private enum Capability {
        static let longPassword: UInt32 = 0x1
        static let connectWithDB: UInt32 = 0x8
        static let protocol41: UInt32 = 0x200
        static let ssl: UInt32 = 0x800
        static let transactions: UInt32 = 0x2000
        static let secureConnection: UInt32 = 0x8000
        static let multiResults: UInt32 = 0x2_0000
        static let pluginAuth: UInt32 = 0x8_0000
    }

    private static let comQuit: UInt8 = 0x01
    private static let comQuery: UInt8 = 0x03
    private static let sslRequestLength = 32
    private static let switchToCleartext: [UInt8] = [0xFE] + Array("mysql_clear_password".utf8) + [0]
    private static let switchToSHA2: [UInt8] = [0xFE] + Array("caching_sha2_password".utf8) + [0]
        + Array("abcdefghijklmnopqrst".utf8) + [0]
    private static let performFullAuthentication: [UInt8] = [0x01, 0x04]
    // ER_QUERY_INTERRUPTED (1317), SQLSTATE 70100.
    private static let interruptedPacket: [UInt8] = [0xFF, 0x25, 0x05] + Array("#70100".utf8)
        + Array("Query execution was interrupted".utf8)
    // ER_ACCESS_DENIED_ERROR (1045), SQLSTATE 28000.
    private static let accessDeniedPacket: [UInt8] = [0xFF, 0x15, 0x04] + Array("#28000".utf8)
        + Array("Access denied for user (using password: YES)".utf8)
    // A utf8mb4 VARCHAR(255) named `n`: catalog, schema, table, org_table, name and org_name, then charset 45, length
    // 1020, type 0xFD, no flags or decimals.
    private static let textColumnDefinition: [UInt8] = ["def", "", "", "", "n", ""]
        .flatMap { FakeMySQLServer.lengthEncoded($0) }
        + [0x0C, 45, 0x00, 0xFC, 0x03, 0x00, 0x00, 0xFD, 0x00, 0x00, 0x00, 0x00, 0x00]

    let port: Int
    private let listener: Int32
    private let asksForCleartext: Bool
    private let asksForFullSHA2Auth: Bool
    private let breaksHandshake: Bool
    private let heldPrefix: String?
    private let holdSeconds: TimeInterval
    private let killedQueriesComplete: Bool
    private let streamedPrefix: String?
    private let streamedRows: Int
    private let serverVersion: String
    private let failures: [String: Failure]
    private let fixtures: URL?
    private let kills = KillBoard()
    private let refusedPasswords = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    var offersTLS: Bool { fixtures != nil || breaksHandshake }

    var heldQueries: Int { kills.heldQueries }

    // Lets a held query on that session answer as completed.
    func release(_ connectionId: UInt32) {
        kills.release(connectionId)
    }

    func refuse(_ password: String) {
        refusedPasswords.withLock { _ = $0.insert(password) }
    }

    init(
        identity: Identity?,
        asksForCleartext: Bool = false,
        asksForFullSHA2Auth: Bool = false,
        breaksHandshake: Bool = false,
        holdsQueriesStarting heldPrefix: String? = nil,
        holdSeconds: TimeInterval = 10,
        killedQueriesComplete: Bool = false,
        streamsRowsStarting streamedPrefix: String? = nil,
        streamedRows: Int = 0,
        serverVersion: String = "8.0.36",
        failures: [String: Failure] = [:]
    ) throws {
        self.asksForCleartext = asksForCleartext
        self.asksForFullSHA2Auth = asksForFullSHA2Auth
        self.breaksHandshake = breaksHandshake
        self.heldPrefix = heldPrefix
        self.holdSeconds = holdSeconds
        self.killedQueriesComplete = killedQueriesComplete
        self.streamedPrefix = streamedPrefix
        self.streamedRows = streamedRows
        self.serverVersion = serverVersion
        self.failures = failures
        if let identity {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FakeMySQLServer-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try TLSTestFixtures.data(identity.certificate).write(to: directory.appendingPathComponent("server.pem"))
            try TLSTestFixtures.data(identity.key).write(to: directory.appendingPathComponent("server.key"))
            fixtures = directory
        } else {
            fixtures = nil
        }

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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
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
        if let fixtures {
            try? FileManager.default.removeItem(at: fixtures)
        }
    }

    func serveOneSession() async -> Session {
        await serve(sessions: 1)[0]
    }

    func serve(sessions count: Int) async -> [Session] {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.TablePro.tests.fake-mysql").async {
                continuation.resume(returning: (0..<count).map { index in
                    guard let client = self.acceptClient() else { return Session() }
                    return self.runSession(on: client, connectionId: UInt32(index + 1))
                })
            }
        }
    }

    // Each session on its own thread, so one can hold a statement while another sends the kill. A session that has
    // not arrived within `acceptingWithin` milliseconds of the one before it is served as empty.
    func serveConcurrently(sessions count: Int, acceptingWithin milliseconds: Int32? = nil) async -> [Session] {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.TablePro.tests.fake-mysql.accept").async {
                let served = SessionList(count: count)
                let group = DispatchGroup()
                for index in 0..<count {
                    let wait = index == 0 ? ServerChannel.pollMilliseconds : milliseconds ?? ServerChannel.pollMilliseconds
                    guard let client = self.acceptClient(within: wait) else { break }
                    group.enter()
                    DispatchQueue(label: "com.TablePro.tests.fake-mysql.session.\(index)").async {
                        served.set(self.runSession(on: client, connectionId: UInt32(index + 1)), at: index)
                        group.leave()
                    }
                }
                group.wait()
                continuation.resume(returning: served.sessions)
            }
        }
    }

    private func runSession(on client: Int32, connectionId: UInt32) -> Session {
        var session = Session(connectionId: connectionId)
        let channel = ServerChannel(socket: client)
        serve(on: channel, into: &session)
        session.plaintext = channel.plaintext
        channel.close()
        return session
    }

    private func serve(on channel: ServerChannel, into session: inout Session) {
        guard channel.send(handshake(connectionId: session.connectionId), sequence: 0),
              var login = channel.readPacket() else { return }

        if offersTLS, login.payload.count == Self.sslRequestLength {
            session.askedForTLS = true
            if breaksHandshake {
                _ = channel.sendRaw(Array(repeating: 0x2A, count: 64))
                return
            }
            guard let fixtures,
                  channel.startTLS(
                      certificatePath: fixtures.appendingPathComponent("server.pem").path,
                      keyPath: fixtures.appendingPathComponent("server.key").path
                  ),
                  let encryptedLogin = channel.readPacket()
            else { return }
            session.encrypted = true
            login = encryptedLogin
        }
        session.sawLogin = true

        var sequence = login.sequence
        if asksForFullSHA2Auth {
            guard channel.send(Self.switchToSHA2, sequence: sequence &+ 1),
                  let scramble = channel.readPacket(),
                  channel.send(Self.performFullAuthentication, sequence: scramble.sequence &+ 1),
                  let answer = channel.readPacket()
            else { return }
            session.fullAuthAnswer = answer.payload
            return
        }
        if asksForCleartext {
            guard channel.send(Self.switchToCleartext, sequence: sequence &+ 1),
                  let answer = channel.readPacket()
            else { return }
            let password = String(decoding: answer.payload.prefix { $0 != 0 }, as: UTF8.self)
            session.cleartextPassword = password
            sequence = answer.sequence
            if refusedPasswords.withLock({ $0.contains(password) }) {
                _ = channel.send(Self.accessDeniedPacket, sequence: sequence &+ 1)
                return
            }
        }
        guard channel.send(Self.okPacket(inTransaction: false), sequence: sequence &+ 1) else { return }
        session.loggedIn = true

        var inTransaction = false
        while let command = channel.readPacket() {
            if command.payload.first == Self.comQuit {
                session.quit = true
                return
            }
            var reply = Self.okPacket(inTransaction: inTransaction)
            if command.payload.first == Self.comQuery {
                let query = String(decoding: command.payload.dropFirst(), as: UTF8.self)
                session.queries.append(query)
                inTransaction = Self.inTransaction(after: query, was: inTransaction)
                reply = Self.okPacket(inTransaction: inTransaction)
                if let failure = failures[query] {
                    guard fail(with: failure, on: channel, after: command.sequence, inTransaction: inTransaction) else { return }
                    continue
                }
                if let streamedPrefix, query.hasPrefix(streamedPrefix) {
                    guard streamRows(on: channel, after: command.sequence, inTransaction: inTransaction, into: &session)
                    else { return }
                    continue
                }
                if let killed = Self.killedSession(in: query) {
                    kills.kill(killed)
                } else if let heldPrefix, query.hasPrefix(heldPrefix),
                          kills.hold(session.connectionId, seconds: holdSeconds) == .killed, !killedQueriesComplete {
                    reply = Self.interruptedPacket
                }
            }
            guard channel.send(reply, sequence: command.sequence &+ 1) else { return }
        }
    }

    // A text result set without CLIENT_DEPRECATE_EOF, which the handshake does not offer: the column count, the column,
    // an EOF, the rows and a closing EOF, or 1317 in place of the rest once a kill for the session arrives.
    private func streamRows(
        on channel: ServerChannel,
        after sequence: UInt8,
        inTransaction: Bool,
        into session: inout Session
    ) -> Bool {
        var next = sequence
        func send(_ payload: [UInt8]) -> Bool {
            next &+= 1
            return channel.send(payload, sequence: next)
        }
        let eof = Self.eofPacket(inTransaction: inTransaction)
        guard send([1]), send(Self.textColumnDefinition), send(eof) else { return false }
        for index in 0..<streamedRows {
            if kills.takeKill(session.connectionId) {
                session.streamWasKilled = true
                return send(Self.interruptedPacket)
            }
            guard send(Self.lengthEncoded("row \(index)")) else { return false }
            session.streamedRowsSent += 1
        }
        return send(eof)
    }

    // Its rows first when it has any, then the error in place of the closing EOF.
    private func fail(with failure: Failure, on channel: ServerChannel, after sequence: UInt8, inTransaction: Bool) -> Bool {
        var next = sequence
        func send(_ payload: [UInt8]) -> Bool {
            next &+= 1
            return channel.send(payload, sequence: next)
        }
        if let rows = failure.rowsFirst {
            guard send([1]), send(Self.textColumnDefinition), send(Self.eofPacket(inTransaction: inTransaction)) else {
                return false
            }
            for index in 0..<rows {
                guard send(Self.lengthEncoded("row \(index)")) else { return false }
            }
        }
        let error = [0xFF, UInt8(failure.code & 0xFF), UInt8(failure.code >> 8)] + Array("#\(failure.sqlState)".utf8)
        return send(error + Array(failure.message.utf8))
    }

    private static func inTransaction(after query: String, was open: Bool) -> Bool {
        let head = query.trimmingCharacters(in: .whitespaces).uppercased()
        if head.hasPrefix("BEGIN") || head.hasPrefix("START TRANSACTION") { return true }
        if head.hasPrefix("COMMIT") || head.hasPrefix("ROLLBACK") { return false }
        return open
    }

    // SERVER_STATUS_AUTOCOMMIT, with SERVER_STATUS_IN_TRANS inside a transaction.
    private static func status(inTransaction: Bool) -> [UInt8] {
        [inTransaction ? 0x03 : 0x02, 0x00]
    }

    private static func okPacket(inTransaction: Bool) -> [UInt8] {
        [0x00, 0x00, 0x00] + status(inTransaction: inTransaction) + [0x00, 0x00]
    }

    // No warnings.
    private static func eofPacket(inTransaction: Bool) -> [UInt8] {
        [0xFE, 0x00, 0x00] + status(inTransaction: inTransaction)
    }

    private static func lengthEncoded(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [UInt8(bytes.count)] + bytes
    }

    private static func killedSession(in query: String) -> UInt32? {
        let words = query.split(separator: " ")
        guard words.count == 3, words[0] == "KILL", words[1] == "QUERY" else { return nil }
        return UInt32(words[2])
    }

    private func handshake(connectionId: UInt32) -> [UInt8] {
        var capabilities = Capability.longPassword | Capability.connectWithDB | Capability.protocol41
            | Capability.transactions | Capability.secureConnection | Capability.multiResults | Capability.pluginAuth
        if offersTLS {
            capabilities |= Capability.ssl
        }
        var payload: [UInt8] = [10]
        payload += Array(serverVersion.utf8) + [0]
        payload += (0..<4).map { UInt8((connectionId >> ($0 * 8)) & 0xFF) }
        payload += Array("abcdefgh".utf8) + [0]
        payload += [UInt8(capabilities & 0xFF), UInt8((capabilities >> 8) & 0xFF)]
        payload += [45, 0x02, 0x00]
        payload += [UInt8((capabilities >> 16) & 0xFF), UInt8((capabilities >> 24) & 0xFF)]
        payload += [21] + [UInt8](repeating: 0, count: 10)
        payload += Array("ijklmnopqrst".utf8) + [0]
        payload += Array("mysql_native_password".utf8) + [0]
        return payload
    }

    private func acceptClient(within milliseconds: Int32 = ServerChannel.pollMilliseconds) -> Int32? {
        var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, milliseconds) > 0 else { return nil }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return client
    }

    // Where a held statement and the kill from another session meet.
    private final class KillBoard: @unchecked Sendable {
        enum HoldEnd {
            case killed
            case released
            case timedOut
        }

        private let condition = NSCondition()
        private var ends: [UInt32: HoldEnd] = [:]
        private var holds = 0

        var heldQueries: Int {
            condition.lock()
            defer { condition.unlock() }
            return holds
        }

        func kill(_ connectionId: UInt32) {
            end(connectionId, as: .killed)
        }

        func release(_ connectionId: UInt32) {
            end(connectionId, as: .released)
        }

        // Without waiting: a session sending rows looks for a kill between them.
        func takeKill(_ connectionId: UInt32) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            guard ends[connectionId] == .killed else { return false }
            ends[connectionId] = nil
            return true
        }

        func hold(_ connectionId: UInt32, seconds: TimeInterval) -> HoldEnd {
            condition.lock()
            defer { condition.unlock() }
            holds += 1
            let deadline = Date(timeIntervalSinceNow: seconds)
            while ends[connectionId] == nil, condition.wait(until: deadline) {}
            return ends.removeValue(forKey: connectionId) ?? .timedOut
        }

        private func end(_ connectionId: UInt32, as end: HoldEnd) {
            condition.lock()
            ends[connectionId] = end
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class SessionList: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Session]

        init(count: Int) {
            list = Array(repeating: Session(), count: count)
        }

        var sessions: [Session] {
            lock.withLock { list }
        }

        func set(_ session: Session, at index: Int) {
            lock.withLock { list[index] = session }
        }
    }

    // Reads and writes MySQL packets on the socket, or inside TLS once `startTLS` succeeds.
    private final class ServerChannel {
        static let pollMilliseconds: Int32 = 10_000

        private(set) var plaintext: [UInt8] = []
        private let socket: Int32
        private var context: OpaquePointer?
        private var ssl: OpaquePointer?
        private var encrypted = false

        init(socket: Int32) {
            self.socket = socket
        }

        func startTLS(certificatePath: String, keyPath: String) -> Bool {
            guard let context = SSL_CTX_new(TLS_server_method()) else { return false }
            self.context = context
            guard SSL_CTX_use_certificate_file(context, certificatePath, SSL_FILETYPE_PEM) == 1,
                  SSL_CTX_use_PrivateKey_file(context, keyPath, SSL_FILETYPE_PEM) == 1,
                  let ssl = SSL_new(context) else { return false }
            self.ssl = ssl
            SSL_set_fd(ssl, socket)
            encrypted = SSL_accept(ssl) == 1
            return encrypted
        }

        func close() {
            if let ssl {
                if encrypted { SSL_shutdown(ssl) }
                SSL_free(ssl)
            }
            if let context { SSL_CTX_free(context) }
            Darwin.close(socket)
        }

        func send(_ payload: [UInt8], sequence: UInt8) -> Bool {
            let length = payload.count
            let header = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), sequence]
            return sendRaw(header + payload)
        }

        func sendRaw(_ bytes: [UInt8]) -> Bool {
            var offset = 0
            while offset < bytes.count {
                let sent = bytes[offset...].withUnsafeBytes { buffer -> Int in
                    if encrypted, let ssl {
                        return Int(SSL_write(ssl, buffer.baseAddress, Int32(buffer.count)))
                    }
                    return Darwin.send(socket, buffer.baseAddress, buffer.count, 0)
                }
                guard sent > 0 else { return false }
                offset += sent
            }
            return true
        }

        func readPacket() -> Packet? {
            guard let header = receive(4) else { return nil }
            let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            guard let payload = length == 0 ? [] : receive(length) else { return nil }
            return Packet(sequence: header[3], payload: payload)
        }

        private func receive(_ count: Int) -> [UInt8]? {
            var bytes: [UInt8] = []
            while bytes.count < count {
                var chunk = [UInt8](repeating: 0, count: count - bytes.count)
                let received: Int
                if encrypted, let ssl {
                    received = Int(SSL_read(ssl, &chunk, Int32(chunk.count)))
                } else {
                    var pollFD = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
                    guard poll(&pollFD, 1, Self.pollMilliseconds) > 0 else { return nil }
                    received = recv(socket, &chunk, chunk.count, 0)
                }
                guard received > 0 else { return nil }
                bytes += chunk.prefix(received)
            }
            if !encrypted {
                plaintext += bytes
            }
            return bytes
        }
    }
}
