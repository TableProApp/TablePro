import Darwin
import Foundation
@testable import TableProMCP
import TableProMCPTestSupport
import TableProTestSupport
import Testing

struct BridgeProxyStampTests {
    private static let discovery = BridgeDiscovery(
        supportedVersions: MCPProtocolVersion.supportedRawValues,
        capabilities: .object([:]),
        serverInfo: nil,
        instructions: nil,
        instanceId: "instance-1"
    )

    private static func app() async throws -> MockHttpServer {
        let server = MockHttpServer()
        await server.setHandler { request in
            guard case .request(let rpc)? = try? JsonRpcCodec.decode(request.body) else {
                return MockHttpResponse(status: 202, headers: [], body: Data())
            }
            let body = try? JsonRpcCodec.encode(.successResponse(JsonRpcSuccessResponse(id: rpc.id, result: .object([:]))))
            return MockHttpResponse(status: 200, headers: [("Content-Type", "application/json")], body: body ?? Data())
        }
        try await server.start()
        return server
    }

    private static func forwarded(_ lines: [String]) async throws -> [Data] {
        let server = try await app()
        let credentials = MCPUpstreamCredentials(socketPath: server.socketPath, serverPID: getpid(), bearerToken: "stamp-token")
        let upstream = MCPStreamableHttpClientTransport(
            configuration: MCPStreamableHttpClientConfiguration(requestTimeout: .seconds(5)),
            credentialsProvider: MCPCachedUpstreamCredentialsProvider(initial: credentials) { credentials },
            errorLogger: nil
        )
        let hostToBridge = Pipe()
        let bridgeToHost = Pipe()
        let proxy = BridgeProxy(
            upstream: upstream,
            discovery: discovery,
            logger: RecordingBridgeLogger(),
            stdin: hostToBridge.fileHandleForReading,
            stdout: bridgeToHost.fileHandleForWriting
        )
        let run = Task { await proxy.run() }
        for line in lines {
            try hostToBridge.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
        var waitFailure: (any Error)?
        do {
            try await waitUntil { await server.requests.count == lines.count }
        } catch {
            waitFailure = error
        }
        try? hostToBridge.fileHandleForWriting.close()
        run.cancel()
        await run.value
        try? bridgeToHost.fileHandleForWriting.close()
        let bodies = await server.requests.map(\.body)
        await server.stop()
        if let waitFailure { throw waitFailure }
        return bodies
    }

    private static func method(of body: Data) throws -> String? {
        try JSONDecoder().decode(JsonValue.self, from: body)["method"]?.stringValue
    }

    private static func instance(in body: Data) throws -> String? {
        try JSONDecoder().decode(JsonValue.self, from: body)["params"]?["_meta"]?[MCPMetaKeys.bridgeInstance]?.stringValue
    }

    @Test("A modern request and a cancellation sent without metadata carry one bridge instance", .timeLimit(.minutes(1)))
    func cancellationMeetsItsModernRequest() async throws {
        let request = #"""
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_connections","_meta":\#
        {"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},\#
        "io.modelcontextprotocol/clientInfo":{"name":"claude-code","version":"2.0.0"}}}}
        """#
        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#

        let bodies = try await Self.forwarded([request, cancel])

        // The two posts race, so each body is told apart by its method.
        let call = try #require(try bodies.first { try Self.method(of: $0) == "tools/call" })
        let cancelled = try #require(try bodies.first { try Self.method(of: $0) == "notifications/cancelled" })
        let requestInstance = try #require(try Self.instance(in: call))
        #expect(try Self.instance(in: cancelled) == requestInstance)
        let stamped = request.replacingOccurrences(
            of: #""_meta":{"#,
            with: #""_meta":{"\#(MCPMetaKeys.bridgeInstance)":"\#(requestInstance)","#
        )
        #expect(String(bytes: call, encoding: .utf8) == stamped, "A modern request gains only the bridge instance")
    }
}
