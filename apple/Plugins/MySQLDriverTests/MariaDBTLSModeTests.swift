import Darwin
import Foundation
import TableProPluginKit
import Testing

// Against the Connector/C 3.4.4 the plugin links, with a loopback server that never offers TLS and
// asks for the password in cleartext, as a man in the middle that strips TLS would.
@Suite(.timeLimit(.minutes(1)))
struct MariaDBTLSModeTests {
    private static let secret = "iam-token-or-password"

    @Test(
        "Required refuses a server without TLS before the password or token is sent",
        arguments: [false, true]
    )
    func requiredRefusesPlaintextServer(signsInWithToken: Bool) async throws {
        let server = try PlaintextMySQLServer()
        defer { server.close() }
        async let session = server.serveOneSession()
        let connection = connection(port: server.port, mode: .required, cleartext: signsInWithToken)

        let error = await #expect(throws: SSLHandshakeError.self) { try await connection.connect() }

        guard case .serverRequiresPlaintext = error else {
            Issue.record("Expected serverRequiresPlaintext, got \(String(describing: error))")
            return
        }
        let served = await session
        #expect(!served.sawLogin)
        #expect(!served.sawInPlaintext(Self.secret))
    }

    @Test("Preferred still signs in to a server without TLS")
    func preferredFallsBack() async throws {
        let server = try PlaintextMySQLServer()
        defer { server.close() }
        async let session = server.serveOneSession()
        let connection = connection(port: server.port, mode: .preferred, cleartext: false)

        try await connection.connect()
        connection.disconnect()

        let served = await session
        #expect(served.sawLogin)
    }

    @Test("The kill connection keeps TLS when the session had it, and Preferred becomes Required there")
    func killConnectionMode() {
        #expect(MariaDBTLSMode.killConnectionMode(.preferred, sessionUsedTLS: true) == .required)
        #expect(MariaDBTLSMode.killConnectionMode(.preferred, sessionUsedTLS: false) == .disabled)
        #expect(MariaDBTLSMode.killConnectionMode(.required, sessionUsedTLS: true) == .required)
        #expect(MariaDBTLSMode.killConnectionMode(.verifyCa, sessionUsedTLS: true) == .verifyCa)
        #expect(MariaDBTLSMode.killConnectionMode(.disabled, sessionUsedTLS: false) == .disabled)
    }

    private func connection(port: Int, mode: SSLMode, cleartext: Bool) -> MariaDBPluginConnection {
        MariaDBPluginConnection(
            transport: .tcp(host: "127.0.0.1", port: UInt32(port)),
            user: "app",
            password: Self.secret,
            database: "",
            sslConfig: SSLConfiguration(mode: mode),
            enableCleartextPlugin: cleartext
        )
    }
}

// One session: a handshake without CLIENT_SSL, then a switch to mysql_clear_password, then OK.
private final class PlaintextMySQLServer: @unchecked Sendable {
    struct SetupFailure: Error {}

    struct Session: Sendable {
        var received: [UInt8] = []
        var sawLogin = false

        func sawInPlaintext(_ secret: String) -> Bool {
            let needle = Array(secret.utf8)
            guard received.count >= needle.count else { return false }
            return (0...(received.count - needle.count)).contains { start in
                received[start..<(start + needle.count)].elementsEqual(needle)
            }
        }
    }

    private static let okPacket: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]
    private static let switchToCleartext: [UInt8] = [0xFE] + Array("mysql_clear_password".utf8) + [0]
    private static let sslRequestLength = 32

    let port: Int
    private let listener: Int32

    init() throws {
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

    func close() {
        Darwin.close(listener)
    }

    func serveOneSession() async -> Session {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "com.TablePro.tests.plaintext-mysql").async {
                continuation.resume(returning: self.runSession())
            }
        }
    }

    private func runSession() -> Session {
        var session = Session()
        var pollFD = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFD, 1, 10_000) > 0 else { return session }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return session }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        guard send(handshake, sequence: 0, to: client), let login = readPacket(client, into: &session) else {
            return session
        }
        guard login.payload.count != Self.sslRequestLength else { return session }
        session.sawLogin = true
        guard send(Self.switchToCleartext, sequence: login.sequence &+ 1, to: client),
              let answer = readPacket(client, into: &session),
              send(Self.okPacket, sequence: answer.sequence &+ 1, to: client)
        else { return session }
        while let command = readPacket(client, into: &session), command.payload.first != 0x01 {
            guard send(Self.okPacket, sequence: command.sequence &+ 1, to: client) else { break }
        }
        return session
    }

    private var handshake: [UInt8] {
        // protocol 4.1, secure connection, plugin auth; no CLIENT_SSL
        let capabilities: UInt32 = 0x1 | 0x8 | 0x200 | 0x2000 | 0x8000 | 0x2_0000 | 0x8_0000
        var payload: [UInt8] = [10] + Array("8.0.36".utf8) + [0] + [1, 0, 0, 0] + Array("abcdefgh".utf8) + [0]
        payload += [UInt8(capabilities & 0xFF), UInt8((capabilities >> 8) & 0xFF), 45, 0x02, 0x00]
        payload += [UInt8((capabilities >> 16) & 0xFF), UInt8((capabilities >> 24) & 0xFF), 21]
        payload += [UInt8](repeating: 0, count: 10) + Array("ijklmnopqrst".utf8) + [0]
        payload += Array("mysql_native_password".utf8) + [0]
        return payload
    }

    private func send(_ payload: [UInt8], sequence: UInt8, to socket: Int32) -> Bool {
        let length = payload.count
        let bytes = [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), sequence] + payload
        return bytes.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) } == bytes.count
    }

    private func readPacket(_ socket: Int32, into session: inout Session) -> (sequence: UInt8, payload: [UInt8])? {
        guard let header = receive(4, from: socket, into: &session) else { return nil }
        let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
        guard let payload = length == 0 ? [] : receive(length, from: socket, into: &session) else { return nil }
        return (header[3], payload)
    }

    private func receive(_ count: Int, from socket: Int32, into session: inout Session) -> [UInt8]? {
        var bytes: [UInt8] = []
        while bytes.count < count {
            var pollFD = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&pollFD, 1, 10_000) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: count - bytes.count)
            let received = recv(socket, &chunk, chunk.count, 0)
            guard received > 0 else { return nil }
            bytes += chunk.prefix(received)
        }
        session.received += bytes
        return bytes
    }
}
