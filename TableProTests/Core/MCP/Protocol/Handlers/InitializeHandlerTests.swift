import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class InitializeHandlerTests: XCTestCase {
    func testHandlerMethodIsInitialize() {
        XCTAssertEqual(InitializeHandler.method, "initialize")
    }

    func testHandlerRequiresNoScopes() {
        XCTAssertTrue(InitializeHandler.requiredScopes.isEmpty)
    }

    func testHandlerOnlyAllowsUninitializedState() {
        XCTAssertEqual(InitializeHandler.allowedSessionStates, [.uninitialized])
    }

    func testHappyPathReturnsServerInfoAndCapabilities() async throws {
        let context = try await makeContext()
        let handler = InitializeHandler()
        let params: JsonValue = .object([
            "protocolVersion": .string("2025-11-25"),
            "clientInfo": .object([
                "name": .string("test-client"),
                "version": .string("1.2.3")
            ]),
            "capabilities": .object([:])
        ])

        let response = try await handler.handle(params: params, context: context)

        guard case .successResponse(let success) = response else {
            XCTFail("Expected success response, got \(response)")
            return
        }

        guard case .object(let result) = success.result else {
            XCTFail("Expected object result")
            return
        }

        XCTAssertEqual(result["protocolVersion"]?.stringValue, "2025-11-25")

        guard let serverInfo = result["serverInfo"], case .object(let serverInfoDict) = serverInfo else {
            XCTFail("Expected serverInfo object")
            return
        }
        XCTAssertEqual(serverInfoDict["name"]?.stringValue, "tablepro")
        XCTAssertNotNil(serverInfoDict["version"]?.stringValue)

        guard let capabilities = result["capabilities"], case .object(let capDict) = capabilities else {
            XCTFail("Expected capabilities object")
            return
        }
        XCTAssertNotNil(capDict["tools"])
        XCTAssertNotNil(capDict["resources"])
        XCTAssertNotNil(capDict["prompts"])
        XCTAssertNotNil(capDict["logging"])
        XCTAssertNotNil(capDict["completions"])
    }

    func testEchoesBackEachSupportedProtocolVersion() async throws {
        for version in ["2025-03-26", "2025-06-18", "2025-11-25"] {
            let context = try await makeContext()
            let handler = InitializeHandler()
            let params: JsonValue = .object([
                "protocolVersion": .string(version),
                "clientInfo": .object(["name": .string("client")])
            ])

            let response = try await handler.handle(params: params, context: context)
            guard case .successResponse(let success) = response,
                  case .object(let result) = success.result else {
                XCTFail("Expected success object for version \(version)")
                return
            }
            XCTAssertEqual(result["protocolVersion"]?.stringValue, version)

            let negotiated = await context.session.negotiatedProtocolVersion
            XCTAssertEqual(negotiated, version)
        }
    }

    func testRecordsClientInfoOnSession() async throws {
        let context = try await makeContext()
        let handler = InitializeHandler()
        let params: JsonValue = .object([
            "protocolVersion": .string("2025-06-18"),
            "clientInfo": .object([
                "name": .string("acme-cli"),
                "version": .string("9.9.9")
            ]),
            "capabilities": .object(["x": .bool(true)])
        ])

        _ = try await handler.handle(params: params, context: context)

        let info = await context.session.clientInfo
        XCTAssertEqual(info?.name, "acme-cli")
        XCTAssertEqual(info?.version, "9.9.9")

        let negotiated = await context.session.negotiatedProtocolVersion
        XCTAssertEqual(negotiated, "2025-06-18")

        let recordedCapabilities = await context.session.clientCapabilities
        XCTAssertEqual(recordedCapabilities, .object(["x": .bool(true)]))
    }

    func testMissingClientInfoFallsBackToUnknown() async throws {
        let context = try await makeContext()
        let handler = InitializeHandler()

        _ = try await handler.handle(params: nil, context: context)

        let info = await context.session.clientInfo
        XCTAssertEqual(info?.name, "unknown")
        XCTAssertNil(info?.version)
    }

    func testRejectsRepeatedInitializeOnSameSession() async throws {
        let context = try await makeContext()
        let handler = InitializeHandler()
        let params: JsonValue = .object([
            "protocolVersion": .string("2025-11-25"),
            "clientInfo": .object(["name": .string("first")])
        ])

        _ = try await handler.handle(params: params, context: context)

        do {
            _ = try await handler.handle(params: params, context: context)
            XCTFail("Expected handler to throw on second initialize")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.invalidRequest)
        }
    }

    func testUnknownProtocolVersionDowngradesToLatest() async throws {
        let context = try await makeContext()
        let handler = InitializeHandler()
        let params: JsonValue = .object([
            "protocolVersion": .string("1999-01-01"),
            "clientInfo": .object(["name": .string("vintage")])
        ])

        let response = try await handler.handle(params: params, context: context)
        guard case .successResponse(let success) = response,
              case .object(let result) = success.result else {
            XCTFail("Expected success object")
            return
        }
        XCTAssertEqual(result["protocolVersion"]?.stringValue, InitializeHandler.supportedProtocolVersion)
        XCTAssertEqual(InitializeHandler.supportedProtocolVersion, "2025-11-25")

        let negotiated = await context.session.negotiatedProtocolVersion
        XCTAssertEqual(negotiated, "2025-11-25")
    }

    func testNewerUnknownProtocolVersionDowngradesToLatest() async throws {
        let context = try await makeContext()
        let handler = InitializeHandler()
        let params: JsonValue = .object([
            "protocolVersion": .string("2099-01-01"),
            "clientInfo": .object(["name": .string("future")])
        ])

        let response = try await handler.handle(params: params, context: context)
        guard case .successResponse(let success) = response,
              case .object(let result) = success.result else {
            XCTFail("Expected success object")
            return
        }
        XCTAssertEqual(result["protocolVersion"]?.stringValue, "2025-11-25")
    }

    func testMissingProtocolVersionFallsBackToSupported() async throws {
        let context = try await makeContext()
        let handler = InitializeHandler()

        _ = try await handler.handle(params: .object([:]), context: context)

        let negotiated = await context.session.negotiatedProtocolVersion
        XCTAssertEqual(negotiated, InitializeHandler.supportedProtocolVersion)
    }

    private func makeContext() async throws -> MCPRequestContext {
        let store = MCPSessionStore()
        let session = try await store.create()
        let sessionId = await session.id
        let progressSink = StubProgressSink()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [InitializeHandler()],
            sessionStore: store,
            progressSink: progressSink
        )
        let request = MCPProtocolTestSupport.makeRequest(method: "initialize")
        let (exchange, _) = MCPProtocolTestSupport.makeExchange(message: request, sessionId: sessionId)
        let token = MCPCancellationToken()
        let emitter = MCPProgressEmitter(
            progressToken: nil,
            target: progressSink,
            sessionId: sessionId
        )
        return MCPRequestContext(
            exchange: exchange,
            session: session,
            principal: MCPProtocolTestSupport.makePrincipal(),
            dispatcher: dispatcher,
            progress: emitter,
            cancellation: token,
            clock: MCPSystemClock()
        )
    }
}
