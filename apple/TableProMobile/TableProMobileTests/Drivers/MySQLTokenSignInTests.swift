import CMariaDB
import CRedis
import Darwin
import Foundation
@testable import TableProMobile
import TableProModels
import TableProTLSTestFixtures
import Testing

@Suite(.timeLimit(.minutes(1)))
struct MySQLTokenSignInTests {
    private static let token = "signed-token"

    @Test("A token is never sent to a server that does not offer TLS, even one that asks for it in cleartext")
    func tokenNeverReachesAPlaintextServer() async throws {
        let server = try FakeMySQLServer(offersTLS: false, asksForCleartext: true)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = tokenDriver(port: server.port)

        let error = await #expect(throws: IAMSignInError.self) { try await driver.connect() }

        #expect(error == .encryptionNotEstablished)
        let served = await session
        #expect(!served.sawInPlaintext(Self.token))
        #expect(!served.loggedIn)
    }

    @Test("A token session answers the cleartext request inside TLS, without a CA to check the certificate against")
    func tokenTravelsInsideTLS() async throws {
        let server = try FakeMySQLServer(offersTLS: true, asksForCleartext: true)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = tokenDriver(port: server.port)

        try await driver.connect()
        try await driver.disconnect()

        let served = await session
        #expect(served.encrypted)
        #expect(served.cleartextPassword == Self.token)
        #expect(!served.sawInPlaintext(Self.token))
        #expect(served.loggedIn)
        #expect(served.quit)
    }

    @Test("Require alone still accepts a server that never offers TLS; only a token session refuses it")
    func requireAloneFallsBackToPlaintext() async throws {
        let server = try FakeMySQLServer(offersTLS: false, asksForCleartext: false)
        defer { server.close() }
        async let session = server.serveOneSession()
        let driver = MySQLDriver(
            host: "127.0.0.1",
            port: server.port,
            user: "app",
            password: "secret",
            database: "",
            ssl: DriverSSLConfiguration(mode: .require)
        )

        try await driver.connect()
        try await driver.disconnect()

        let served = await session
        #expect(!served.encrypted)
        #expect(served.loggedIn)
        #expect(!served.queries.isEmpty)
        #expect(served.quit)
    }

    @Test("Only a token session refused for a server without TLS is an encryption failure")
    func connectFailure() {
        let sslError = UInt32(CR_SSL_CONNECTION_ERROR)
        let offersTLS = UInt(CLIENT_SSL)

        #expect(
            MySQLTokenSignIn.connectFailure(signsInWithToken: true, errorCode: sslError, serverCapabilities: 0)
                == .encryptionNotEstablished
        )
        #expect(
            MySQLTokenSignIn.connectFailure(signsInWithToken: true, errorCode: sslError, serverCapabilities: offersTLS)
                == nil
        )
        #expect(
            MySQLTokenSignIn.connectFailure(signsInWithToken: false, errorCode: sslError, serverCapabilities: 0) == nil
        )
        #expect(
            MySQLTokenSignIn.connectFailure(
                signsInWithToken: true,
                errorCode: UInt32(CR_CONN_HOST_ERROR),
                serverCapabilities: 0
            ) == nil
        )
    }

    private func tokenDriver(port: Int) -> MySQLDriver {
        MySQLDriver(
            host: "127.0.0.1",
            port: port,
            user: "iam_user",
            password: Self.token,
            database: "",
            ssl: DriverSSLConfiguration(mode: .require),
            signsInWithToken: true
        )
    }
}

// One loopback session that accepts any login. With `offersTLS` it upgrades after the client's SSL
// request; with `asksForCleartext` it answers the login with a switch to mysql_clear_password, as RDS does.
private final class FakeMySQLServer: @unchecked Sendable {
    struct SetupFailure: Error {}

    struct Session: Sendable {
        var plaintext: [UInt8] = []
        var encrypted = false
        var cleartextPassword: String?
        var loggedIn = false
        var queries: [String] = []
        var quit = false

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
    private static let okPacket: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]
    private static let sslRequestLength = 32
    private static let switchToCleartext: [UInt8] = [0xFE] + Array("mysql_clear_password".utf8) + [0]

    let port: Int
    private let listener: Int32
    private let offersTLS: Bool
    private let asksForCleartext: Bool
    private let fixtures: URL?

    init(offersTLS: Bool, asksForCleartext: Bool) throws {
        self.offersTLS = offersTLS
        self.asksForCleartext = asksForCleartext
        if offersTLS {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MySQLTokenSignInTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try TLSTestFixtures.data(TLSTestFixtures.serverCertificate)
                .write(to: directory.appendingPathComponent("server.pem"))
            try TLSTestFixtures.data(TLSTestFixtures.serverKey)
                .write(to: directory.appendingPathComponent("server.key"))
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
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.TablePro.tests.fake-mysql").async {
                continuation.resume(returning: self.runSession())
            }
        }
    }

    private func runSession() -> Session {
        var session = Session()
        guard let client = acceptClient() else { return session }
        let channel = ServerChannel(socket: client)
        serve(on: channel, into: &session)
        session.plaintext = channel.plaintext
        channel.close()
        return session
    }

    private func serve(on channel: ServerChannel, into session: inout Session) {
        guard channel.send(handshake, sequence: 0), var login = channel.readPacket() else { return }

        if offersTLS, login.payload.count == Self.sslRequestLength {
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

        var sequence = login.sequence
        if asksForCleartext {
            guard channel.send(Self.switchToCleartext, sequence: sequence &+ 1),
                  let answer = channel.readPacket()
            else { return }
            session.cleartextPassword = String(decoding: answer.payload.prefix { $0 != 0 }, as: UTF8.self)
            sequence = answer.sequence
        }
        guard channel.send(Self.okPacket, sequence: sequence &+ 1) else { return }
        session.loggedIn = true

        while let command = channel.readPacket() {
            if command.payload.first == Self.comQuit {
                session.quit = true
                return
            }
            if command.payload.first == Self.comQuery {
                session.queries.append(String(decoding: command.payload.dropFirst(), as: UTF8.self))
            }
            guard channel.send(Self.okPacket, sequence: command.sequence &+ 1) else { return }
        }
    }

    private var handshake: [UInt8] {
        var capabilities = Capability.longPassword | Capability.connectWithDB | Capability.protocol41
            | Capability.transactions | Capability.secureConnection | Capability.multiResults | Capability.pluginAuth
        if offersTLS {
            capabilities |= Capability.ssl
        }
        var payload: [UInt8] = [10]
        payload += Array("8.0.36".utf8) + [0]
        payload += [1, 0, 0, 0]
        payload += Array("abcdefgh".utf8) + [0]
        payload += [UInt8(capabilities & 0xFF), UInt8((capabilities >> 8) & 0xFF)]
        payload += [45, 0x02, 0x00]
        payload += [UInt8((capabilities >> 16) & 0xFF), UInt8((capabilities >> 24) & 0xFF)]
        payload += [21] + [UInt8](repeating: 0, count: 10)
        payload += Array("ijklmnopqrst".utf8) + [0]
        payload += Array("mysql_native_password".utf8) + [0]
        return payload
    }

    private func acceptClient() -> Int32? {
        var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, ServerChannel.pollMilliseconds) > 0 else { return nil }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return client
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
            let bytes = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), sequence]
                + payload
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
