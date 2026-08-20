//
//  SOCKSProxyManagerTests.swift
//  TableProTests
//

import Foundation
import Network
import os
import Testing

@testable import TablePro

@Suite("SOCKS proxy manager", .serialized)
struct SOCKSProxyManagerTests {
    private func config(port: Int, username: String = "") -> SOCKSProxyConfiguration {
        SOCKSProxyConfiguration(host: "127.0.0.1", port: port, username: username)
    }

    private func expectPortEventuallyFree(_ port: Int, host: String = "127.0.0.1") async {
        for _ in 0..<100 {
            if await !LoopbackPort.isReachable(host: host, port: port) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(await !LoopbackPort.isReachable(host: host, port: port))
    }

    @Test("invalid configuration is rejected without touching the network")
    func invalidConfiguration() async {
        let manager = SOCKSProxyManager(connectTimeout: 1)
        await #expect(throws: SOCKSProxyError.invalidConfiguration) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: SOCKSProxyConfiguration(host: "", port: 1_080),
                password: nil,
                targetHost: "db.example.com",
                targetPort: 5_432
            )
        }
        await #expect(throws: SOCKSProxyError.invalidConfiguration) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: SOCKSProxyConfiguration(host: "127.0.0.1", port: 0),
                password: nil,
                targetHost: "db.example.com",
                targetPort: 5_432
            )
        }
        await #expect(throws: SOCKSProxyError.invalidConfiguration) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: SOCKSProxyConfiguration(host: "127.0.0.1", port: 1_080),
                password: nil,
                targetHost: "db.example.com",
                targetPort: 70_000
            )
        }
    }

    @Test("bytes round-trip through the proxy to the target")
    func byteRoundTrip() async throws {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 5)
        let connectionId = UUID()
        let localPort = try await manager.createTunnel(
            connectionId: connectionId,
            config: config(port: server.port),
            password: nil,
            targetHost: "db.internal.example",
            targetPort: 5_432
        )
        defer { Task { try await manager.closeTunnel(connectionId: connectionId) } }

        let client = try await TestTCPClient.connect(port: localPort)
        defer { client.cancel() }
        let payload = Data("SELECT 1".utf8)
        try await client.send(payload)
        let echoed = try await client.receive(count: payload.count)
        #expect(echoed == payload)
        #expect(await manager.hasTunnel(connectionId: connectionId))
    }

    @Test("the target hostname reaches the proxy unresolved")
    func remoteDNS() async throws {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 5)
        let connectionId = UUID()
        _ = try await manager.createTunnel(
            connectionId: connectionId,
            config: config(port: server.port),
            password: nil,
            targetHost: "only-resolves-behind-the-bastion.internal",
            targetPort: 3_306
        )
        defer { Task { try await manager.closeTunnel(connectionId: connectionId) } }

        let request = try #require(server.capturedConnectRequest)
        #expect(request.addressType == 0x03)
        #expect(request.address == Data("only-resolves-behind-the-bastion.internal".utf8))
        #expect(request.port == 3_306)
    }

    @Test("username and password are negotiated per RFC 1929")
    func credentialNegotiation() async throws {
        let server = FakeSOCKS5Server(behavior: .echo, username: "tester", password: "s3cret")
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 5)
        let connectionId = UUID()
        _ = try await manager.createTunnel(
            connectionId: connectionId,
            config: config(port: server.port, username: "tester"),
            password: "s3cret",
            targetHost: "db.internal.example",
            targetPort: 5_432
        )
        defer { Task { try await manager.closeTunnel(connectionId: connectionId) } }

        #expect(server.sawAuthNegotiation)
    }

    @Test("rejected credentials fail tunnel creation")
    func rejectedCredentials() async throws {
        let server = FakeSOCKS5Server(behavior: .rejectAuth, username: "tester", password: "expected")
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 2)
        let connectionId = UUID()
        await #expect(throws: SOCKSProxyError.self) {
            _ = try await manager.createTunnel(
                connectionId: connectionId,
                config: config(port: server.port, username: "tester"),
                password: "wrong",
                targetHost: "db.internal.example",
                targetPort: 5_432
            )
        }
        #expect(await !manager.hasTunnel(connectionId: connectionId))
    }

    @Test("an unreachable proxy times out within the deadline")
    func proxyUnreachable() async throws {
        let freePort = try #require(LoopbackPort.allocateFree())
        let manager = SOCKSProxyManager(connectTimeout: 1)
        let started = Date()
        await #expect(throws: SOCKSProxyError.self) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: config(port: freePort),
                password: nil,
                targetHost: "db.internal.example",
                targetPort: 5_432
            )
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("a silent proxy times out within the deadline")
    func silentProxyTimesOut() async throws {
        let server = FakeSOCKS5Server(behavior: .neverReply)
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 1)
        await #expect(throws: SOCKSProxyError.connectTimedOut(proxyHost: "127.0.0.1", proxyPort: server.port)) {
            _ = try await manager.createTunnel(
                connectionId: UUID(),
                config: config(port: server.port),
                password: nil,
                targetHost: "db.internal.example",
                targetPort: 5_432
            )
        }
    }

    @Test("cancelling tunnel creation returns promptly")
    func cancellationDuringCreate() async throws {
        let server = FakeSOCKS5Server(behavior: .neverReply)
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 30)
        let connectionId = UUID()
        let creation = Task {
            try await manager.createTunnel(
                connectionId: connectionId,
                config: config(port: server.port),
                password: nil,
                targetHost: "db.internal.example",
                targetPort: 5_432
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        creation.cancel()
        await #expect(throws: (any Error).self) { _ = try await creation.value }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await !manager.hasTunnel(connectionId: connectionId))
    }

    @Test("two concurrent clients relay independently through one tunnel")
    func concurrentClients() async throws {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 5)
        let connectionId = UUID()
        let localPort = try await manager.createTunnel(
            connectionId: connectionId,
            config: config(port: server.port),
            password: nil,
            targetHost: "db.internal.example",
            targetPort: 5_432
        )
        defer { Task { try await manager.closeTunnel(connectionId: connectionId) } }

        async let first: Data = {
            let client = try await TestTCPClient.connect(port: localPort)
            defer { client.cancel() }
            try await client.send(Data("first-payload".utf8))
            return try await client.receive(count: "first-payload".utf8.count)
        }()
        async let second: Data = {
            let client = try await TestTCPClient.connect(port: localPort)
            defer { client.cancel() }
            try await client.send(Data("second".utf8))
            return try await client.receive(count: "second".utf8.count)
        }()

        let results = try await (first, second)
        #expect(results.0 == Data("first-payload".utf8))
        #expect(results.1 == Data("second".utf8))
        #expect(await manager.hasTunnel(connectionId: connectionId))
    }

    @Test("closing the tunnel frees the local port")
    func closeTunnelFreesPort() async throws {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 5)
        let connectionId = UUID()
        let localPort = try await manager.createTunnel(
            connectionId: connectionId,
            config: config(port: server.port),
            password: nil,
            targetHost: "db.internal.example",
            targetPort: 5_432
        )
        #expect(await manager.hasTunnel(connectionId: connectionId))
        #expect(await manager.getLocalPort(connectionId: connectionId) == localPort)

        try await manager.closeTunnel(connectionId: connectionId)
        #expect(await !manager.hasTunnel(connectionId: connectionId))
        #expect(await manager.getLocalPort(connectionId: connectionId) == nil)
        await expectPortEventuallyFree(localPort)
    }

    @Test("recreating a tunnel for the same connection replaces the old one")
    func recreateReplacesExisting() async throws {
        let server = FakeSOCKS5Server(behavior: .echo)
        try await server.start()
        defer { server.stop() }

        let manager = SOCKSProxyManager(connectTimeout: 5)
        let connectionId = UUID()
        let firstPort = try await manager.createTunnel(
            connectionId: connectionId,
            config: config(port: server.port),
            password: nil,
            targetHost: "db.internal.example",
            targetPort: 5_432
        )
        let secondPort = try await manager.createTunnel(
            connectionId: connectionId,
            config: config(port: server.port),
            password: nil,
            targetHost: "db.internal.example",
            targetPort: 5_432
        )
        defer { Task { try await manager.closeTunnel(connectionId: connectionId) } }

        #expect(await manager.getLocalPort(connectionId: connectionId) == secondPort)
        await expectPortEventuallyFree(firstPort)
    }
}

private struct TestTCPClient {
    let connection: NWConnection

    static func connect(port: Int) async throws -> TestTCPClient {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw POSIXError(.EINVAL) }
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: (Result<Void, Error>) -> Void = { result in
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(CancellationError()))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        return TestTCPClient(connection: connection)
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? NWError.posix(.ECONNRESET))
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}
