//
//  LibPQDirectTLSTests.swift
//  PostgreSQLDriverTests
//

import Darwin
import Foundation
import TableProPluginKit
import Testing

// A listener that answers neither TLS nor sign-in: a TLS ClientHello is hung up on, as a proxy that needs an SSLRequest
// does, and an SSLRequest is refused, so the connect ends without a session and each attempt's first bytes are kept.
private final class DirectTLSRefusingServer: @unchecked Sendable {
    enum Attempt: Equatable {
        case tlsClientHello
        case sslRequest
        case other
    }

    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var seen: [Attempt] = []

    var attempts: [Attempt] { lock.withLock { seen } }

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        try #require(socketFD >= 0 && bound == 0 && Darwin.listen(socketFD, 4) == 0 && gotName == 0)
        listener = socketFD
        port = Int(named.sin_port.bigEndian)
        DispatchQueue(label: "com.TablePro.tests.direct-tls").async { [self] in acceptLoop() }
    }

    func close() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var buffer = [UInt8](repeating: 0, count: 8)
            let count = recv(client, &buffer, buffer.count, 0)
            let attempt = Self.classify(Array(buffer.prefix(max(count, 0))))
            lock.withLock { seen.append(attempt) }
            if attempt == .sslRequest { _ = send(client, [UInt8(ascii: "N")], 1, 0) }
            Darwin.close(client)
        }
    }

    private static func classify(_ bytes: [UInt8]) -> Attempt {
        if bytes.first == 0x16 { return .tlsClientHello }
        return bytes == [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F] ? .sslRequest : .other
    }
}

@Suite(.timeLimit(.minutes(1)))
struct LibPQDirectTLSTests {
    private static func connection(to server: DirectTLSRefusingServer, memory: LibPQDirectTLSMemory) -> LibPQPluginConnection {
        LibPQPluginConnection(
            host: "127.0.0.1",
            port: server.port,
            user: "postgres",
            password: nil,
            database: "postgres",
            sslConfig: SSLConfiguration(mode: .required),
            directTLS: memory
        )
    }

    private static func endpoint(of server: DirectTLSRefusingServer) -> LibPQDirectTLSMemory.Endpoint {
        LibPQDirectTLSMemory.Endpoint(host: "127.0.0.1", port: server.port, serverName: nil)
    }

    @Test("A server proven direct that turns the handshake away is asked the standard way, still requiring TLS")
    func refusedHandshakeFallsBack() async throws {
        let server = try DirectTLSRefusingServer()
        defer { server.close() }
        let memory = LibPQDirectTLSMemory()
        memory.noteDirectBackend(Self.endpoint(of: server))
        let connection = Self.connection(to: server, memory: memory)
        defer { connection.disconnect() }

        await #expect(throws: (any Error).self) { try await connection.connect() }

        #expect(server.attempts == [.tlsClientHello, .sslRequest])
        #expect(!memory.allowsDirect(Self.endpoint(of: server)))
    }

    @Test("A server never proven gets the standard negotiation alone")
    func unknownServerNegotiatesTheStandardWay() async throws {
        let server = try DirectTLSRefusingServer()
        defer { server.close() }
        let connection = Self.connection(to: server, memory: LibPQDirectTLSMemory())
        defer { connection.disconnect() }

        await #expect(throws: (any Error).self) { try await connection.connect() }

        #expect(server.attempts == [.sslRequest])
    }

    @Test("A refusal outlives a later proof")
    func refusalIsRemembered() {
        let memory = LibPQDirectTLSMemory()
        let endpoint = LibPQDirectTLSMemory.Endpoint(host: "db", port: 5_432, serverName: nil)

        memory.noteRefused(endpoint)
        memory.noteDirectBackend(endpoint)

        #expect(!memory.allowsDirect(endpoint))
    }

    @Test("Only an attempt that ended before sign-in counts as a refused handshake", arguments: [
        (LibPQHandshakeProgress(startedEncryption: true, startedSignIn: false), true),
        (LibPQHandshakeProgress(startedEncryption: true, startedSignIn: true), false),
        (LibPQHandshakeProgress(startedEncryption: false, startedSignIn: false), false),
    ])
    func refusalNeedsAnUnfinishedHandshake(progress: LibPQHandshakeProgress, refused: Bool) {
        #expect(progress.refusedDirectTLS == refused)
    }
}
