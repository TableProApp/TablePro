import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import Testing

private final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var total: Int {
        lock.withLock { calls }
    }

    func record() {
        lock.withLock { calls += 1 }
    }
}

// G0F69IT6: after TablePro goes away, a request reaches only a listener that proved it wrote the handshake.
private struct TakeoverRig {
    let folder: URL
    let logger = RecordingBridgeLogger()
    let launches = LaunchRecorder()

    func socketPath(_ name: String = MCPSocketLocation.fileName) -> String {
        folder.appendingPathComponent(name, isDirectory: false).path
    }

    func writeHandshake(instanceId: String, socketPath: String) throws {
        let payload = MCPHandshakePayload(
            socketPath: socketPath,
            token: "tp_\(instanceId)",
            pid: ProcessInfo.processInfo.processIdentifier,
            instanceId: instanceId,
            protocolVersion: MCPProtocolVersion.latest.rawValue,
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let url = MCPHandshakeLocation.file(in: folder)
        try? FileManager.default.removeItem(at: url)
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: try MCPHandshakeCoding.encoder().encode(payload),
            attributes: [.posixPermissions: 0o600]
        )
        try #require(created)
    }

    func removeHandshake() throws {
        try FileManager.default.removeItem(at: MCPHandshakeLocation.file(in: folder))
    }

    // Stands in for TablePro: server/discover advertises `advertising`, a tool call names the instance.
    func app(instanceId: String, socketPath: String, advertising: String? = nil) async throws -> MockHttpServer {
        let server = MockHttpServer(socketPath: socketPath)
        let advertised = advertising ?? instanceId
        await server.setHandler { request in
            guard case .request(let rpc)? = try? JsonRpcCodec.decode(request.body) else { return nil }
            let result: JsonValue
            if rpc.method == "server/discover" {
                result = .object([
                    "supportedVersions": .array([.string(MCPProtocolVersion.latest.rawValue)]),
                    "capabilities": .object([:]),
                    "_meta": .object([MCPServerInstanceIdentity.metaKey: .string(advertised)])
                ])
            } else {
                result = .object(["answeredBy": .string(instanceId)])
            }
            let body = try? JsonRpcCodec.encode(.successResponse(JsonRpcSuccessResponse(id: rpc.id, result: result)))
            return MockHttpResponse(status: 200, headers: [("Content-Type", "application/json")], body: body ?? Data())
        }
        try await server.start()
        return server
    }

    func acquirer(
        pollTimeout: Duration = .seconds(10),
        launch: @escaping @Sendable () throws -> Void = {}
    ) -> MCPHandshakeAcquirer {
        let launches = launches
        return MCPHandshakeAcquirer(
            logger: logger,
            supportDirectory: folder,
            pollTimeout: pollTimeout,
            launchHostApp: { _ in
                launches.record()
                try launch()
            }
        )
    }

    // Wired the way BridgeMain wires it.
    func bridgeUpstream(acquirer: MCPHandshakeAcquirer) async throws -> MCPStreamableHttpClientTransport {
        let opening = try await BridgeUpstreamHandshake.acquireVerified(acquirer: acquirer, logger: logger)
        return MCPStreamableHttpClientTransport(
            configuration: MCPStreamableHttpClientConfiguration(requestTimeout: .seconds(10)),
            credentialsProvider: BridgeUpstreamHandshake.credentialsProvider(
                opening: opening,
                acquirer: acquirer,
                logger: logger
            ),
            errorLogger: logger
        )
    }
}

private func withRig(_ body: (TakeoverRig) async throws -> Void) async throws {
    let rig = TakeoverRig(folder: try MCPTestSocketFolder.make())
    defer { try? FileManager.default.removeItem(at: rig.folder) }
    try await body(rig)
}

private func toolCall(id: Int64, sql: String) throws -> MCPUpstreamFrame {
    let params: JsonValue = .object([
        "name": .string("execute_query"),
        "arguments": .object(["query": .string(sql)])
    ])
    let body = try JsonRpcCodec.encode(.request(JsonRpcRequest(id: .number(id), method: "tools/call", params: params)))
    return MCPUpstreamFrame(body: body, method: "tools/call", name: "execute_query", requestId: .number(id))
}

private func text(_ data: Data) -> String {
    String(bytes: data, encoding: .utf8) ?? ""
}

private func methods(_ server: MockHttpServer) async -> [String] {
    await server.requests.map { $0.header("Mcp-Method") ?? "" }
}

struct BridgeUpstreamTakeoverTests {
    @Test("After TablePro restarts, the next request goes out only once the new handshake is verified", .timeLimit(.minutes(1)))
    func reacquiresAndVerifiesBeforeResending() async throws {
        try await withRig { rig in
            let first = try await rig.app(instanceId: "first", socketPath: rig.socketPath())
            try rig.writeHandshake(instanceId: "first", socketPath: rig.socketPath())
            let upstream = try await rig.bridgeUpstream(acquirer: rig.acquirer())
            var inbound = upstream.inbound.makeAsyncIterator()

            try await upstream.send(try toolCall(id: 1, sql: "SELECT 1"))
            let answered = try #require(try await inbound.next())
            #expect(text(answered).contains("\"first\""))

            await first.stop()
            try rig.removeHandshake()

            try await upstream.send(try toolCall(id: 2, sql: "SELECT card_number FROM payments"))
            let restarted = rig.socketPath("restarted.sock")
            let second = try await rig.app(instanceId: "second", socketPath: restarted)
            try rig.writeHandshake(instanceId: "second", socketPath: restarted)

            let reply = try #require(try await inbound.next())
            guard case .successResponse(let success) = try JsonRpcCodec.decode(reply) else {
                Issue.record("Expected the resent request to succeed: \(text(reply))")
                return
            }
            #expect(success.id == .number(2))
            #expect(success.result["answeredBy"]?.stringValue == "second")
            #expect(await methods(first) == ["server/discover", "tools/call"])
            #expect(await methods(second) == ["server/discover", "tools/call"])
            #expect(await second.requests.last?.header("Authorization") == "Bearer tp_second")
            #expect(rig.launches.total == 0)

            await upstream.close()
            await second.stop()
        }
    }

    @Test("A listener that does not prove it wrote the handshake never receives the request", .timeLimit(.minutes(1)))
    func unverifiedListenerNeverSeesTheRequest() async throws {
        try await withRig { rig in
            let first = try await rig.app(instanceId: "first", socketPath: rig.socketPath())
            try rig.writeHandshake(instanceId: "first", socketPath: rig.socketPath())
            let upstream = try await rig.bridgeUpstream(acquirer: rig.acquirer())
            var inbound = upstream.inbound.makeAsyncIterator()

            await first.stop()
            try rig.removeHandshake()

            try await upstream.send(try toolCall(id: 2, sql: "SELECT card_number FROM payments"))
            let impostorPath = rig.socketPath("impostor.sock")
            let impostor = try await rig.app(instanceId: "second", socketPath: impostorPath, advertising: "someone-else")
            try rig.writeHandshake(instanceId: "second", socketPath: impostorPath)

            let reply = try #require(try await inbound.next())
            guard case .errorResponse(let failure) = try JsonRpcCodec.decode(reply) else {
                Issue.record("Expected an error, got \(text(reply))")
                return
            }
            #expect(failure.id == .number(2))
            #expect(failure.error.message.contains("not reachable"))
            #expect(await methods(impostor) == ["server/discover"])
            #expect(await methods(first) == ["server/discover"])

            await upstream.close()
            await impostor.stop()
        }
    }

    @Test("A request after the user quit TablePro does not relaunch it, and is sent nowhere", .timeLimit(.minutes(1)))
    func refreshNeverRelaunchesTheApp() async throws {
        try await withRig { rig in
            let first = try await rig.app(instanceId: "first", socketPath: rig.socketPath())
            try rig.writeHandshake(instanceId: "first", socketPath: rig.socketPath())
            let upstream = try await rig.bridgeUpstream(acquirer: rig.acquirer(pollTimeout: .seconds(1)))
            var inbound = upstream.inbound.makeAsyncIterator()

            await first.stop()
            try rig.removeHandshake()

            try await upstream.send(try toolCall(id: 2, sql: "SELECT card_number FROM payments"))
            let reply = try #require(try await inbound.next())
            guard case .errorResponse(let failure) = try JsonRpcCodec.decode(reply) else {
                Issue.record("Expected an error, got \(text(reply))")
                return
            }
            #expect(failure.id == .number(2))
            #expect(failure.error.message.contains("not reachable"))
            #expect(rig.launches.total == 0)
            #expect(await methods(first) == ["server/discover"])
            #expect(!FileManager.default.fileExists(atPath: rig.socketPath()))

            await upstream.close()
        }
    }

    @Test("Bridge startup still launches TablePro when no handshake exists", .timeLimit(.minutes(1)))
    func startupLaunchesTheApp() async throws {
        try await withRig { rig in
            let app = try await rig.app(instanceId: "first", socketPath: rig.socketPath())
            let acquirer = rig.acquirer {
                try rig.writeHandshake(instanceId: "first", socketPath: rig.socketPath())
            }

            let opening = try await BridgeUpstreamHandshake.acquireVerified(acquirer: acquirer, logger: rig.logger)
            #expect(opening.handshake.instanceId == "first")
            #expect(rig.launches.total == 1)

            await app.stop()
        }
    }
}
