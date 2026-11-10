import Darwin
import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import TableProTestSupport
import Testing

private func withServer(_ body: (MockHttpServer) async throws -> Void) async throws {
    let server = MockHttpServer()
    try await server.start()
    do {
        try await body(server)
    } catch {
        await server.stop()
        throw error
    }
    await server.stop()
}

private func upstream(_ server: MockHttpServer) -> MCPStreamableHttpClientTransport {
    let credentials = MCPUpstreamCredentials(socketPath: server.socketPath, serverPID: getpid(), bearerToken: "tp_bridge")
    return MCPStreamableHttpClientTransport(
        configuration: MCPStreamableHttpClientConfiguration(requestTimeout: .seconds(10)),
        credentialsProvider: MCPCachedUpstreamCredentialsProvider(initial: credentials) { credentials }
    )
}

private func frame(_ method: String, id: Int64, name: String? = nil) -> MCPUpstreamFrame {
    let body = Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":{}}"#.utf8)
    return MCPUpstreamFrame(body: body, method: method, name: name, requestId: .number(id))
}

private func sseBody(_ payloads: [String]) -> Data {
    Data(payloads.map { "data: \($0)\n\n" }.joined(separator: ": keep-alive\n\n").utf8)
}

private func request(_ path: String = "/mcp", headers: [(String, String)] = []) -> MCPSocketHttpRequest {
    MCPSocketHttpRequest(path: path, headers: headers, body: Data("{}".utf8))
}

struct MCPUnixSocketHttpClientTests {
    @Test("A JSON response comes back byte for byte, and the request carries the bridge's headers")
    func jsonRoundTrip() async throws {
        try await withServer { server in
            let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{"exact":1.0,"huge":123456789012345678901}}"#.utf8)
            await server.respondWithJson(body)
            let transport = upstream(server)
            var inbound = transport.inbound.makeAsyncIterator()

            try await transport.send(frame("tools/call", id: 1, name: "café"))
            #expect(try await inbound.next() == body)

            let sent = try #require(await server.requests.first)
            #expect(sent.method == "POST")
            #expect(sent.path == "/mcp")
            #expect(sent.header("Host") == "localhost")
            #expect(sent.header("Authorization") == "Bearer tp_bridge")
            #expect(sent.header("Mcp-Method") == "tools/call")
            #expect(sent.header("Mcp-Name").flatMap(MCPBase64Sentinel.decode) == "café")
            #expect(sent.header("MCP-Protocol-Version") == MCPProtocolVersion.latest.rawValue)
            await transport.close()
        }
    }

    @Test("A chunked response is reassembled whole")
    func chunkedResponse() async throws {
        try await withServer { server in
            var body = Data(#"{"jsonrpc":"2.0","id":2,"result":{"text":""#.utf8)
            body.append(Data(repeating: 0x61, count: 200_000))
            body.append(Data(#""}}"#.utf8))
            await server.setResponse(MockHttpResponse(
                status: 200,
                headers: [("Content-Type", "application/json")],
                body: body,
                framing: .chunked(size: 4_096)
            ))

            let response = try await MCPUnixSocketHttpClient.send(request(), socketPath: server.socketPath, expectedPID: getpid(), idleTimeout: .seconds(10))
            #expect(response.status == 200)
            #expect(response.headers.value(for: "Transfer-Encoding") == "chunked")
            #expect(try await response.collectBody() == body)

            let transport = upstream(server)
            var inbound = transport.inbound.makeAsyncIterator()
            try await transport.send(frame("tools/list", id: 2))
            #expect(try await inbound.next() == body)
            await transport.close()
        }
    }

    @Test("An event stream that ends when the server closes arrives frame by frame, in order", arguments: [
        MockHttpResponse.Framing.untilClose,
        MockHttpResponse.Framing.chunked(size: 7)
    ])
    func eventStream(framing: MockHttpResponse.Framing) async throws {
        try await withServer { server in
            let progress = #"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.5}}"#
            let result = #"{"jsonrpc":"2.0","id":3,"result":{"done":true}}"#
            await server.setResponse(MockHttpResponse(
                status: 200,
                headers: [("Content-Type", "text/event-stream")],
                body: sseBody([progress, result]),
                framing: framing
            ))
            let transport = upstream(server)
            var inbound = transport.inbound.makeAsyncIterator()

            try await transport.send(frame("tools/call", id: 3, name: "run"))
            #expect(try await inbound.next() == Data(progress.utf8))
            #expect(try await inbound.next() == Data(result.utf8))
            await transport.close()
        }
    }

    @Test("Discovery accepts its answer before an event stream closes")
    func discoveryOnOpenEventStream() async throws {
        let folder = try MCPTestSocketFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let held = HeldConnections()
        defer { held.closeAll() }
        let response = JsonRpcSuccessResponse(id: .string("tablepro-bridge-discover"), result: .object([
            "supportedVersions": .array([.string(MCPProtocolVersion.latest.rawValue)]),
            "capabilities": .object([:]),
            "_meta": .object([MCPServerInstanceIdentity.metaKey: .string("test-instance")])
        ]))
        let payload = try JsonRpcCodec.encode(.successResponse(response))
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: ".utf8)
            + payload + Data("\n\n".utf8)
        let listener = MCPUnixSocketListener(path: MCPSocketLocation.primarySocket(in: folder).path) { connection in
            held.keep(connection)
            connection.start { _ in }
            connection.receive(maximumLength: 65_536) { _, _, _ in
                connection.send(reply) { _ in }
            }
        }
        try listener.start()
        defer { listener.stop() }
        let handshake = MCPHandshakePayload(
            socketPath: listener.path, token: "tp_bridge", pid: getpid(), instanceId: "test-instance",
            protocolVersion: MCPProtocolVersion.latest.rawValue, expiresAt: Date().addingTimeInterval(60)
        )
        let discovery = try await BridgeUpstreamHandshake.verifiedDiscovery(
            handshake: handshake, credentials: handshake.credentials(), logger: RecordingBridgeLogger()
        )
        #expect(discovery.instanceId == "test-instance")
    }

    @Test("A changed peer is refused before the listener receives any bytes")
    func changedPeerReceivesNothing() async throws {
        let folder = try MCPTestSocketFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (received, continuation) = AsyncStream<Data>.makeStream()
        let listener = MCPUnixSocketListener(path: MCPSocketLocation.primarySocket(in: folder).path) { connection in
            connection.start { _ in }
            connection.receive(maximumLength: 65_536) { bytes, _, _ in
                continuation.yield(bytes ?? Data())
                continuation.finish()
                connection.cancel()
            }
        }
        try listener.start()
        defer { listener.stop() }

        await #expect(throws: MCPSocketHttpError.peerChanged) {
            _ = try await MCPUnixSocketHttpClient.send(
                request(headers: [("Authorization", "Bearer tp_secret")]),
                socketPath: listener.path,
                expectedPID: getpid() + 1,
                idleTimeout: .seconds(5)
            )
        }
        var iterator = received.makeAsyncIterator()
        #expect(await iterator.next() == Data())
    }

    @Test("Cancelling a request before its headers arrive closes the socket")
    func cancelPendingResponse() async throws {
        let folder = try MCPTestSocketFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (accepted, continuation) = AsyncStream<MCPUnixSocketConnection>.makeStream()
        let listener = MCPUnixSocketListener(path: MCPSocketLocation.primarySocket(in: folder).path) { connection in
            continuation.yield(connection)
            continuation.finish()
        }
        try listener.start()
        defer { listener.stop() }
        let task = Task {
            try await MCPUnixSocketHttpClient.send(
                request(), socketPath: listener.path, expectedPID: getpid(), idleTimeout: .seconds(10)
            )
        }
        var iterator = accepted.makeAsyncIterator()
        let connection = try #require(await iterator.next())
        defer { connection.cancel() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("A socket nobody listens on is a connect failure, so nothing was sent")
    func missingSocket() async throws {
        let path = MCPSocketLocation.primarySocket(in: MCPTestSocketFolder.url()).path
        await #expect {
            _ = try await MCPUnixSocketHttpClient.send(request(), socketPath: path, expectedPID: getpid(), idleTimeout: .seconds(5))
        } throws: { error in
            guard case MCPSocketHttpError.connectFailed = error else { return false }
            return true
        }
    }

    @Test("A path that does not fit in sun_path is refused before any connection")
    func overlongPath() async throws {
        let path = "/" + String(repeating: "a", count: MCPSocketLocation.maxPathBytes)
        await #expect(throws: MCPSocketHttpError.invalidSocketPath(path)) {
            _ = try await MCPUnixSocketHttpClient.send(request(), socketPath: path, expectedPID: getpid(), idleTimeout: .seconds(5))
        }
    }

    @Test("A header value carrying a line break is refused rather than sent")
    func headerInjection() async throws {
        try await withServer { server in
            await #expect(throws: MCPSocketHttpError.invalidHeader("Mcp-Method")) {
                _ = try await MCPUnixSocketHttpClient.send(
                    request(headers: [("Mcp-Method", "tools/list\r\nX-Injected: 1")]),
                    socketPath: server.socketPath,
                    expectedPID: getpid(), idleTimeout: .seconds(5)
                )
            }
            #expect(await server.requests.isEmpty)
        }
    }

    @Test("A listener that never answers times out instead of hanging")
    func silentListenerTimesOut() async throws {
        let folder = try MCPTestSocketFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let held = HeldConnections()
        let listener = MCPUnixSocketListener(path: MCPSocketLocation.primarySocket(in: folder).path) { connection in
            held.keep(connection)
        }
        try listener.start()
        defer { listener.stop() }

        await #expect(throws: MCPSocketHttpError.timedOut) {
            _ = try await MCPUnixSocketHttpClient.send(request(), socketPath: listener.path, expectedPID: getpid(), idleTimeout: .milliseconds(200))
        }
        held.closeAll()
    }
}

private final class HeldConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [MCPUnixSocketConnection] = []

    func keep(_ connection: MCPUnixSocketConnection) {
        lock.withLock { connections.append(connection) }
    }

    func closeAll() {
        lock.withLock { connections }.forEach { $0.cancel() }
    }
}
