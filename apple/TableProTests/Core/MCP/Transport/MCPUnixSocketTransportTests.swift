import Darwin
import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import Testing

private actor ExchangeLog {
    private(set) var addresses: [MCPClientAddress] = []

    func record(_ address: MCPClientAddress) {
        addresses.append(address)
    }
}

private struct SocketServer {
    let transport: MCPHttpServerTransport
    let socketPath: String
    let log: ExchangeLog

    func tcpPort() async throws -> UInt16 {
        try #require(await transport.listeningPort)
    }
}

private func withSocketServer(
    allowedPeerUid: uid_t = getuid(),
    authenticator: any MCPAuthenticator = StubAlwaysAllowAuthenticator(),
    pairingService: MCPPairingService? = nil,
    limits: MCPHttpServerLimits = .standard,
    prepare: (String) throws -> Void = { _ in },
    body: (SocketServer) async throws -> Void
) async throws {
    let folder = try MCPTestSocketFolder.make()
    defer { try? FileManager.default.removeItem(at: folder) }
    let socketPath = MCPSocketLocation.primarySocket(in: folder).path
    try prepare(socketPath)

    let pairing: MCPPairingService
    if let pairingService {
        pairing = pairingService
    } else {
        pairing = await MCPPairingService()
    }
    let transport = MCPHttpServerTransport(
        configuration: .loopback(port: 0, socketPath: socketPath, limits: limits),
        authenticator: authenticator,
        pairingService: pairing,
        tokenRevoker: StubUnknownTokenRevoker(),
        allowedSocketPeerUid: allowedPeerUid
    )
    try await transport.start()
    let log = ExchangeLog()
    let consumer = StubExchangeConsumer()
    await consumer.start(transport: transport) { exchange in
        await log.record(exchange.context.clientAddress)
        await MCPTransportTestHandlers.echo(exchange)
    }
    do {
        try await body(SocketServer(transport: transport, socketPath: socketPath, log: log))
    } catch {
        await consumer.stop()
        await MCPTransportTestHarness.stop(transport)
        throw error
    }
    await consumer.stop()
    await MCPTransportTestHarness.stop(transport)
}

private func toolsListHeaders(token: String) -> [(String, String)] {
    var headers = MCPTransportTestRequests.standardHeaders(method: "tools/list")
    headers.removeAll { $0.0 == "Authorization" }
    headers.append(("Authorization", "Bearer \(token)"))
    return headers
}

private func toolsListBody() throws -> Data {
    try MCPTransportTestRequests.requestBody(id: 1, method: "tools/list", params: MCPTransportTestRequests.params())
}

private func toolsList(token: String = "test-token") throws -> MCPSocketHttpRequest {
    MCPSocketHttpRequest(path: "/mcp", headers: toolsListHeaders(token: token), body: try toolsListBody())
}

private func overTcp(_ request: Data, port: UInt16) async throws -> RawHttpTestResponse {
    let client = RawHttpTestClient(port: port)
    try await client.connect()
    defer { Task { await client.close() } }
    try await client.send(request)
    return try await client.readResponse()
}

private func overSocket(_ request: MCPSocketHttpRequest, path: String) async throws -> (Int, Data) {
    let response = try await MCPUnixSocketHttpClient.send(request, socketPath: path, idleTimeout: .seconds(10))
    return (response.status, try await response.collectBody())
}

private func exchangeBody() throws -> Data {
    let verifier = String((UUID().uuidString + UUID().uuidString).filter { $0.isLetter || $0.isNumber }.prefix(64))
    return try JSONSerialization.data(withJSONObject: ["code": "unknown-\(UUID().uuidString)", "code_verifier": verifier])
}

private func isSocket(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
}

// A crash leaves the socket file behind with nobody listening on it.
private func leaveStaleSocket(at path: String) throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
    }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try #require(bound == 0)
}

struct MCPUnixSocketTransportTests {
    @Test("The Unix socket serves an MCP request through the same router as TCP, as a local client")
    func socketServesThroughTheRouter() async throws {
        try await withSocketServer { server in
            let response = try await MCPUnixSocketHttpClient.send(
                try toolsList(),
                socketPath: server.socketPath,
                idleTimeout: .seconds(10)
            )
            #expect(response.status == 200)
            #expect(response.headers.value(for: "Content-Type") == "application/json")
            let message = try JsonRpcCodec.decode(try await response.collectBody())
            guard case .successResponse(let success) = message else {
                Issue.record("Expected a result, got \(message)")
                return
            }
            #expect(success.result["method"]?.stringValue == "tools/list")
            #expect(success.result["protocolVersion"]?.stringValue == MCPProtocolVersion.latest.rawValue)
            #expect(await server.log.addresses == [.localSocket])
            #expect(await server.transport.listeningPort != nil, "external clients keep the TCP port")
        }
    }

    @Test("A peer running as another user is closed before it reaches the router")
    func foreignPeerIsRefused() async throws {
        try await withSocketServer(allowedPeerUid: getuid() + 1) { server in
            await #expect {
                _ = try await MCPUnixSocketHttpClient.send(
                    try toolsList(),
                    socketPath: server.socketPath,
                    idleTimeout: .seconds(10)
                )
            } throws: { error in
                switch error {
                case MCPSocketHttpError.connectionClosed, MCPSocketHttpError.connectFailed:
                    return true
                default:
                    return false
                }
            }
            #expect(await server.log.addresses.isEmpty)
        }
    }

    @Test("Stopping the server removes its socket file")
    func stopRemovesTheSocket() async throws {
        try await withSocketServer { server in
            #expect(isSocket(server.socketPath))
            await server.transport.stop()
            #expect(!FileManager.default.fileExists(atPath: server.socketPath))
        }
    }

    @Test("A socket file a crashed TablePro left behind is replaced at start")
    func staleSocketIsReplaced() async throws {
        try await withSocketServer(prepare: leaveStaleSocket(at:)) { server in
            let response = try await MCPUnixSocketHttpClient.send(
                try toolsList(),
                socketPath: server.socketPath,
                idleTimeout: .seconds(10)
            )
            #expect(response.status == 200)
        }
    }

    @Test("A file at the socket path that is not a socket stops the server from starting")
    func foreignFileBlocksTheStart() async throws {
        let folder = try MCPTestSocketFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socketPath = MCPSocketLocation.primarySocket(in: folder).path
        try #require(FileManager.default.createFile(atPath: socketPath, contents: Data("keep".utf8)))

        let transport = MCPHttpServerTransport(
            configuration: .loopback(port: 0, socketPath: socketPath),
            authenticator: StubAlwaysAllowAuthenticator(),
            pairingService: await MCPPairingService(),
            tokenRevoker: StubUnknownTokenRevoker()
        )
        await #expect(throws: MCPHttpServerError.self) {
            try await transport.start()
        }
        await MCPTransportTestHarness.stop(transport)
        #expect(FileManager.default.contents(atPath: socketPath) == Data("keep".utf8))
    }

    @Test("Bad tokens another account sends over TCP never lock the socket out")
    func tcpAuthFailuresDoNotLockTheSocket() async throws {
        let store = FakeMCPTokenStore()
        await store.register("tp_bridge", validated: MCPValidatedToken(
            tokenId: UUID(),
            label: "bridge",
            scopes: MCPScope.readOnlySet,
            connectionAccess: .all,
            issuedAt: Date(),
            expiresAt: nil
        ))
        let authenticator = MCPBearerTokenAuthenticator(tokenStore: store, rateLimiter: MCPRateLimiter())
        try await withSocketServer(authenticator: authenticator) { server in
            let port = try await server.tcpPort()
            let guess = MCPTransportTestRequests.raw(port: port, headers: toolsListHeaders(token: "tp_guess"), body: try toolsListBody())
            var statuses: [Int] = []
            for _ in 0..<6 {
                statuses.append(try await overTcp(guess, port: port).statusCode)
            }
            #expect(statuses.last == 429)
            let valid = MCPTransportTestRequests.raw(port: port, headers: toolsListHeaders(token: "tp_bridge"), body: try toolsListBody())
            #expect(try await overTcp(valid, port: port).statusCode == 429, "the TCP loopback key is locked")

            let (status, _) = try await overSocket(try toolsList(token: "tp_bridge"), path: server.socketPath)
            #expect(status == 200)
        }
    }

    @Test("Failed pairing exchanges over TCP never lock the socket out")
    func tcpPairingFailuresDoNotLockTheSocket() async throws {
        let pairing = await MCPPairingService(store: PairingExchangeStore())
        try await withSocketServer(pairingService: pairing) { server in
            let port = try await server.tcpPort()
            var statuses: [Int] = []
            for _ in 0..<6 {
                let request = MCPTransportTestRequests.raw(
                    path: "/v1/integrations/exchange",
                    port: port,
                    headers: [("Content-Type", "application/json")],
                    body: try exchangeBody()
                )
                statuses.append(try await overTcp(request, port: port).statusCode)
            }
            #expect(statuses.last == 429)

            let request = MCPSocketHttpRequest(
                path: "/v1/integrations/exchange",
                headers: [("Content-Type", "application/json")],
                body: try exchangeBody()
            )
            let (status, _) = try await overSocket(request, path: server.socketPath)
            #expect(status == 404, "an unknown code, not a lockout")
        }
    }

    @Test("Connections held open over TCP never take the socket's connection slots")
    func tcpConnectionsDoNotFillTheSocket() async throws {
        let limits = MCPHttpServerLimits(
            maxRequestBodyBytes: 1_024 * 1_024,
            maxHeaderBytes: 16 * 1_024,
            connectionTimeout: .seconds(10),
            maxConcurrentConnections: 1
        )
        try await withSocketServer(limits: limits) { server in
            let port = try await server.tcpPort()
            let holder = RawHttpTestClient(port: port)
            try await holder.connect()
            defer { Task { await holder.close() } }
            try await holder.send(try MCPTransportTestRequests.modernPost(port: port, id: 1, method: "tools/list"))
            #expect(try await holder.readResponse().statusCode == 200)

            let extra = RawHttpTestClient(port: port)
            try await extra.connect()
            defer { Task { await extra.close() } }
            #expect(try await extra.readResponse().statusCode == 503, "the TCP listener is full")

            let (status, _) = try await overSocket(try toolsList(), path: server.socketPath)
            #expect(status == 200)
        }
    }
}
