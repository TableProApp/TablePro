import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class MCPBridgeIntegrationTests: XCTestCase {
    private var upstream: MockHttpServer!

    override func setUp() async throws {
        try await super.setUp()
        upstream = MockHttpServer()
        try await upstream.start()
    }

    override func tearDown() async throws {
        await upstream.stop()
        upstream = nil
        try await super.tearDown()
    }

    func testALegacyInitializeIsAnsweredByTheBridgeItself() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }

        try bridge.write(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18",\#
        "clientInfo":{"name":"LegacyHost","version":"9.9.9"},"capabilities":{}}}
        """#)

        let response = try await bridge.nextMessage()
        guard case .successResponse(let success) = response else {
            XCTFail("Expected a success response, got \(response)")
            return
        }
        XCTAssertEqual(success.id, .number(1))
        XCTAssertEqual(success.result["protocolVersion"]?.stringValue, MCPProtocolVersion.v20250618.rawValue)
        XCTAssertEqual(success.result["serverInfo"]?["name"]?.stringValue, "TablePro")
        XCTAssertEqual(success.result["instructions"]?.stringValue, BridgeIntegrationFixtures.instructions)

        let forwarded = await upstream.requests
        XCTAssertTrue(forwarded.isEmpty, "initialize is terminated locally and never reaches the app")
    }

    func testTheAdvertisedLegacyCapabilitiesDropWhatALegacyHostCannotUse() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }

        try bridge.write(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let response = try await bridge.nextMessage()
        guard case .successResponse(let success) = response else {
            XCTFail("Expected a success response")
            return
        }

        let capabilities = try XCTUnwrap(success.result["capabilities"])
        XCTAssertNil(capabilities["extensions"], "Modern extensions mean nothing to a legacy host")
        XCTAssertEqual(capabilities["resources"]?["subscribe"]?.boolValue, false)
        XCTAssertNotNil(capabilities["tools"])
        XCTAssertNotNil(capabilities["prompts"])
    }

    func testAnUnsupportedRequestedVersionNegotiatesDownToTheNewestLegacyOne() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }

        try bridge.write(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
        """#)

        let response = try await bridge.nextMessage()
        guard case .successResponse(let success) = response else {
            XCTFail("Expected a success response")
            return
        }
        XCTAssertEqual(success.result["protocolVersion"]?.stringValue, MCPProtocolVersion.v20251125.rawValue)
    }

    func testTheInitializedNotificationIsSwallowed() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }

        await upstream.respondWithJson(try Self.successBody(id: .number(2)))
        try bridge.write(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try bridge.write(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)

        _ = try await bridge.nextMessage()
        let forwarded = await upstream.requests
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded[0].header("Mcp-Method"), "tools/list")
    }

    func testPingIsAnsweredLocally() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }

        try bridge.write(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)

        let response = try await bridge.nextMessage()
        guard case .successResponse(let success) = response else {
            XCTFail("Expected a success response")
            return
        }
        XCTAssertEqual(success.id, .number(3))
        XCTAssertEqual(success.result, .object([:]))

        let forwarded = await upstream.requests
        XCTAssertTrue(forwarded.isEmpty)
    }

    func testALegacyHostRequestIsStampedWithSynthesisedMetadata() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(4)))

        try bridge.write(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25",\#
        "clientInfo":{"name":"LegacyHost","version":"9.9.9"},"capabilities":{}}}
        """#)
        _ = try await bridge.nextMessage()

        try bridge.write(#"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"cursor":"abc"}}"#)
        _ = try await bridge.nextMessage()

        let recordedForwarded = await upstream.requests.first

        let forwarded = try XCTUnwrap(recordedForwarded)
        let body = try JSONDecoder().decode(JsonValue.self, from: forwarded.body)
        let meta = try XCTUnwrap(body["params"]?["_meta"])

        XCTAssertEqual(meta[MCPMetaKeys.protocolVersion]?.stringValue, MCPProtocolVersion.latest.rawValue)
        XCTAssertEqual(meta[MCPMetaKeys.clientCapabilities], .object([:]))
        XCTAssertEqual(meta[MCPMetaKeys.clientInfo]?["name"]?.stringValue, "LegacyHost")
        XCTAssertEqual(meta[MCPMetaKeys.clientInfo]?["version"]?.stringValue, "9.9.9")
        XCTAssertEqual(body["params"]?["cursor"]?.stringValue, "abc")
    }

    func testARequestWithNoParamsGainsAParamsObjectCarryingTheMetadata() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(5)))

        try bridge.write(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        _ = try await bridge.nextMessage()

        let recordedForwarded = await upstream.requests.first

        let forwarded = try XCTUnwrap(recordedForwarded)
        let body = try JSONDecoder().decode(JsonValue.self, from: forwarded.body)
        XCTAssertEqual(
            body["params"]?["_meta"]?[MCPMetaKeys.protocolVersion]?.stringValue,
            MCPProtocolVersion.latest.rawValue
        )
    }

    func testAModernHostRequestIsForwardedByteForByte() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(6)))

        let line = #"""
        {"jsonrpc":"2.0","id":6,"method":"tools/list","params":{"_meta":\#
        {"io.modelcontextprotocol/protocolVersion":"2026-07-28",\#
        "io.modelcontextprotocol/clientCapabilities":{}}}}
        """#
        try bridge.write(line)
        _ = try await bridge.nextMessage()

        let recordedForwarded = await upstream.requests.first

        let forwarded = try XCTUnwrap(recordedForwarded)
        XCTAssertEqual(forwarded.body, Data(line.utf8), "A modern host already carries its own metadata")
    }

    func testStampingNeverRewritesTheNumbersInAMessage() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(7)))

        let line = #"""
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"execute_query",\#
        "arguments":{"exact":1.0,"huge":123456789012345678901,"negative":-0.0}}}
        """#
        try bridge.write(line)
        _ = try await bridge.nextMessage()

        let recordedForwarded = await upstream.requests.first

        let forwarded = try XCTUnwrap(recordedForwarded)
        let text = try XCTUnwrap(String(data: forwarded.body, encoding: .utf8))

        XCTAssertTrue(text.contains("\"exact\":1.0"), "1.0 must not arrive as 1")
        XCTAssertTrue(text.contains("\"huge\":123456789012345678901"), "A huge integer must not be rounded")
        XCTAssertTrue(text.contains("\"negative\":-0.0"))
        XCTAssertTrue(text.contains(MCPMetaKeys.protocolVersion))
    }

    func testAModernMessageWithBigNumbersIsForwardedUntouched() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(8)))

        let line = #"""
        {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"execute_query",\#
        "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"},\#
        "arguments":{"exact":1.0,"huge":123456789012345678901}}}
        """#
        try bridge.write(line)
        _ = try await bridge.nextMessage()

        let recordedForwarded = await upstream.requests.first

        let forwarded = try XCTUnwrap(recordedForwarded)
        XCTAssertEqual(forwarded.body, Data(line.utf8))
    }

    func testAToolCallCarriesItsNameInTheHeader() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(9)))

        try bridge.write(#"""
        {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"list_tables","arguments":{}}}
        """#)
        _ = try await bridge.nextMessage()

        let recordedForwarded = await upstream.requests.first

        let forwarded = try XCTUnwrap(recordedForwarded)
        XCTAssertEqual(forwarded.header("Mcp-Name"), "list_tables")
        XCTAssertEqual(forwarded.header("Mcp-Method"), "tools/call")
    }

    func testTheBridgeNeverSendsASessionHeaderUpstream() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.setResponse(MockHttpResponse(
            status: 200,
            headers: [("Content-Type", "application/json"), ("Mcp-Session-Id", "server-minted")],
            body: try Self.successBody(id: .number(10))
        ))

        try bridge.write(#"{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}"#)
        _ = try await bridge.nextMessage()
        try bridge.write(#"{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{}}"#)
        _ = try await bridge.nextMessage()

        let forwarded = await upstream.requests
        XCTAssertEqual(forwarded.count, 2)
        for request in forwarded {
            XCTAssertNil(request.header("Mcp-Session-Id"))
            XCTAssertEqual(request.method, "POST")
        }
    }

    func testTheBridgeNeverPingsUpstreamToKeepAnythingWarm() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }

        try await Task.sleep(for: .milliseconds(400))

        let forwarded = await upstream.requests
        XCTAssertTrue(forwarded.isEmpty, "There is no session upstream, so there is nothing to keep alive")
    }

    func testAnUpstreamAnswerReachesTheHostVerbatim() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }

        let body = Data(#"{"jsonrpc":"2.0","id":12,"result":{"exact":1.0,"cursor":"abc"}}"#.utf8)
        await upstream.respondWithJson(body)

        try bridge.write(#"{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}"#)

        let line = try await bridge.nextLine()
        XCTAssertEqual(line, body, "The bridge relays the app's bytes without decoding them")
    }

    func testAForwardThatFailsAnswersTheHostInsteadOfLeavingItWaiting() async throws {
        let bridge = try await startBridge(upstreamPort: 1)
        defer { bridge.shutdown() }

        try bridge.write(#"{"jsonrpc":"2.0","id":13,"method":"tools/list","params":{}}"#)

        let response = try await bridge.nextMessage(timeout: 10)
        guard case .errorResponse(let failure) = response else {
            XCTFail("Expected an error response, got \(response)")
            return
        }
        XCTAssertEqual(failure.id, .number(13))
        XCTAssertFalse(failure.error.message.isEmpty)
    }

    func testAResponseWrittenToStdinIsDropped() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(14)))

        try bridge.write(#"{"jsonrpc":"2.0","id":99,"result":{"ok":true}}"#)
        try bridge.write(#"{"jsonrpc":"2.0","id":14,"method":"tools/list","params":{}}"#)
        _ = try await bridge.nextMessage()

        let forwarded = await upstream.requests
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded[0].header("Mcp-Method"), "tools/list")
    }

    func testAMalformedLineIsDropped() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(15)))

        try bridge.write("this is not json")
        try bridge.write(#"{"jsonrpc":"2.0","id":15,"method":"tools/list","params":{}}"#)
        _ = try await bridge.nextMessage()

        let forwarded = await upstream.requests
        XCTAssertEqual(forwarded.count, 1)
    }

    func testAMessageWithNoMethodIsDropped() async throws {
        let bridge = try await startBridge()
        defer { bridge.shutdown() }
        await upstream.respondWithJson(try Self.successBody(id: .number(16)))

        try bridge.write(#"{"jsonrpc":"2.0","id":50}"#)
        try bridge.write(#"{"jsonrpc":"2.0","id":16,"method":"tools/list","params":{}}"#)
        _ = try await bridge.nextMessage()

        let forwarded = await upstream.requests
        XCTAssertEqual(forwarded.count, 1)
    }

    private func startBridge(upstreamPort: UInt16? = nil) async throws -> BridgeHarness {
        let port = upstreamPort ?? upstream.port
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let credentials = MCPUpstreamCredentials(endpoint: endpoint, bearerToken: "integration-token")
        let transport = MCPStreamableHttpClientTransport(
            configuration: MCPStreamableHttpClientConfiguration(requestTimeout: .seconds(5)),
            credentialsProvider: MCPCachedUpstreamCredentialsProvider(initial: credentials) { credentials },
            errorLogger: nil
        )
        return BridgeHarness(upstream: transport, discovery: BridgeIntegrationFixtures.discovery)
    }

    private static func successBody(id: JsonRpcId) throws -> Data {
        try JsonRpcCodec.encode(
            .successResponse(JsonRpcSuccessResponse(id: id, result: .object(["ok": .bool(true)])))
        )
    }
}

enum BridgeIntegrationFixtures {
    static let instructions = "Query TablePro connections through these tools."

    static let discovery = BridgeDiscovery(
        supportedVersions: MCPProtocolVersion.supportedRawValues,
        capabilities: .object([
            "tools": .object(["listChanged": .bool(true)]),
            "prompts": .object(["listChanged": .bool(true)]),
            "resources": .object(["subscribe": .bool(true), "listChanged": .bool(true)]),
            "completions": .object([:]),
            "extensions": .object(["io.tablepro/subscriptions": .object([:])])
        ]),
        serverInfo: .object(["name": .string("TablePro"), "version": .string("1.2.3")]),
        instructions: instructions,
        instanceId: "instance-1"
    )
}

final class BridgeHarness: @unchecked Sendable {
    private let hostToBridge = Pipe()
    private let bridgeToHost = Pipe()
    private let output = BridgeOutputBuffer()
    private let proxy: BridgeProxy
    private let runTask: Task<Void, Never>

    init(upstream: MCPStreamableHttpClientTransport, discovery: BridgeDiscovery) {
        proxy = BridgeProxy(
            upstream: upstream,
            discovery: discovery,
            logger: RecordingBridgeLogger(),
            stdin: hostToBridge.fileHandleForReading,
            stdout: bridgeToHost.fileHandleForWriting
        )
        let buffer = output
        bridgeToHost.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
        }
        let runner = proxy
        runTask = Task { await runner.run() }
    }

    func write(_ line: String) throws {
        var payload = Data(line.utf8)
        payload.append(0x0A)
        try hostToBridge.fileHandleForWriting.write(contentsOf: payload)
    }

    func nextLine(timeout: TimeInterval = 5) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = output.take() {
                return line
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BridgeIntegrationError.timeout
    }

    func nextMessage(timeout: TimeInterval = 5) async throws -> JsonRpcMessage {
        try JsonRpcCodec.decode(try await nextLine(timeout: timeout))
    }

    func shutdown() {
        bridgeToHost.fileHandleForReading.readabilityHandler = nil
        try? hostToBridge.fileHandleForWriting.close()
        runTask.cancel()
        try? bridgeToHost.fileHandleForWriting.close()
    }
}

final class BridgeOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex ..< newline])
            buffer.removeSubrange(buffer.startIndex ... newline)
            guard !line.isEmpty else { continue }
            lines.append(line)
        }
    }

    func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
}

enum BridgeIntegrationError: Error {
    case timeout
}
