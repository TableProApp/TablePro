//
//  MySQLSessionSocketKeepaliveTests.swift
//  MySQLDriverTests
//

import Darwin
import Foundation
import TableProPluginKit
import Testing

// The test process holds the connection's end of the socket, so its options are read off it after the sign-in.
@Suite(.timeLimit(.minutes(1)))
struct MySQLSessionSocketKeepaliveTests {
    @Test("A session dialed over TCP probes a silent peer, so a lost reply fails in about 90 s rather than hours")
    func sessionSocketTakesTheKeepalive() async throws {
        let server = try PlaintextMySQLServer(asksForCleartext: false)
        defer { server.close() }
        async let session = server.serveOneSession()
        let connection = MariaDBPluginConnection(
            transport: .tcp(host: "127.0.0.1", port: UInt32(server.port)),
            user: "app",
            password: "app-password",
            database: "",
            sslConfig: SSLConfiguration(mode: .disabled),
            enableCleartextPlugin: false
        )

        try await connection.connect()
        let socket = try #require(Self.clientSocket(connectedTo: server.port))
        let keepalive = Self.intOption(socket, SOL_SOCKET, SO_KEEPALIVE)
        let idle = Self.intOption(socket, IPPROTO_TCP, TCP_KEEPALIVE)
        let interval = Self.intOption(socket, IPPROTO_TCP, TCP_KEEPINTVL)
        let probes = Self.intOption(socket, IPPROTO_TCP, TCP_KEEPCNT)
        connection.disconnect()
        _ = await session

        #expect(keepalive != 0)
        #expect(idle == 60)
        #expect(interval == 10)
        #expect(probes == 3)
    }

    private static func clientSocket(connectedTo port: Int) -> Int32? {
        (0..<getdtablesize()).first { descriptor in
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(descriptor, $0, &length) }
            }
            return named == 0 && address.sin_family == sa_family_t(AF_INET) && Int(address.sin_port.bigEndian) == port
        }
    }

    private static func intOption(_ socket: Int32, _ level: Int32, _ name: Int32) -> Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socket, level, name, &value, &length)
        return value
    }
}
