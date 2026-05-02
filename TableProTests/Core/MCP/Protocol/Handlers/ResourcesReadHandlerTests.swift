import Foundation
@testable import TablePro
import XCTest

final class ResourcesReadHandlerTests: XCTestCase {
    func testMethodIsResourcesRead() {
        XCTAssertEqual(ResourcesReadHandler.method, "resources/read")
    }

    func testRequiresResourcesReadScope() {
        XCTAssertEqual(ResourcesReadHandler.requiredScopes, [.resourcesRead])
    }

    func testReadsConnectionsList() async throws {
        let (handler, context) = try await makeContext()
        let params: JsonValue = .object(["uri": .string("tablepro://connections")])

        let response = try await handler.handle(params: params, context: context)

        guard case .successResponse(let success) = response else {
            XCTFail("Expected success response, got \(response)")
            return
        }

        let contents = success.result["contents"]?.arrayValue
        XCTAssertEqual(contents?.count, 1)
        let entry = contents?.first
        XCTAssertEqual(entry?["uri"]?.stringValue, "tablepro://connections")
        XCTAssertEqual(entry?["mimeType"]?.stringValue, "application/json")
        XCTAssertNotNil(entry?["text"]?.stringValue)
    }

    func testMissingUriThrowsInvalidParams() async throws {
        let (handler, context) = try await makeContext()
        do {
            _ = try await handler.handle(params: .object([:]), context: context)
            XCTFail("Expected MCPProtocolError")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        }
    }

    func testInvalidUriThrowsInvalidParams() async throws {
        let (handler, context) = try await makeContext()
        let params: JsonValue = .object(["uri": .string("not a url at all spaces")])

        do {
            _ = try await handler.handle(params: params, context: context)
            XCTFail("Expected MCPProtocolError")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        }
    }

    func testNonTableproSchemeRejected() async throws {
        let (handler, context) = try await makeContext()
        let params: JsonValue = .object(["uri": .string("https://example.com/foo")])

        do {
            _ = try await handler.handle(params: params, context: context)
            XCTFail("Expected MCPProtocolError")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        }
    }

    func testUnknownPathReturnsMethodNotFound() async throws {
        let (handler, context) = try await makeContext()
        let params: JsonValue = .object(["uri": .string("tablepro://unknown/resource")])

        do {
            _ = try await handler.handle(params: params, context: context)
            XCTFail("Expected MCPProtocolError")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.methodNotFound)
        }
    }

    func testInvalidUuidInSchemaPathRejected() async throws {
        let (handler, context) = try await makeContext()
        let params: JsonValue = .object(["uri": .string("tablepro://connections/not-a-uuid/schema")])

        do {
            _ = try await handler.handle(params: params, context: context)
            XCTFail("Expected MCPProtocolError")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        }
    }

    private func makeContext(
        clock: any MCPClock = MCPSystemClock()
    ) async throws -> (ResourcesReadHandler, MCPRequestContext) {
        let store = MCPSessionStore(clock: clock)
        let session = try await store.create()
        try await session.transitionToReady()
        let progressSink = StubProgressSink()
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
        let dispatcher = MCPProtocolDispatcher(
            handlers: [ResourcesReadHandler(services: services)],
            sessionStore: store,
            progressSink: progressSink,
            clock: clock
        )
        let request = MCPProtocolTestSupport.makeRequest(method: "resources/read")
        let principal = MCPProtocolTestSupport.makePrincipal(scopes: [.resourcesRead])
        let sessionId = await session.id
        let (exchange, _) = MCPProtocolTestSupport.makeExchange(
            message: request,
            sessionId: sessionId,
            principal: principal
        )
        let token = MCPCancellationToken()
        let emitter = MCPProgressEmitter(
            progressToken: nil,
            target: progressSink,
            sessionId: sessionId
        )
        let context = MCPRequestContext(
            exchange: exchange,
            session: session,
            principal: principal,
            dispatcher: dispatcher,
            progress: emitter,
            cancellation: token,
            clock: clock
        )
        return (ResourcesReadHandler(services: services), context)
    }
}
