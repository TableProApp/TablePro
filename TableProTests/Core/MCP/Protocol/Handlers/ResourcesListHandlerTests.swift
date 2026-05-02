import Foundation
@testable import TablePro
import XCTest

final class ResourcesListHandlerTests: XCTestCase {
    func testMethodIsResourcesList() {
        XCTAssertEqual(ResourcesListHandler.method, "resources/list")
    }

    func testRequiresResourcesReadScope() {
        XCTAssertEqual(ResourcesListHandler.requiredScopes, [.resourcesRead])
    }

    func testAllowedInReadyState() {
        XCTAssertEqual(ResourcesListHandler.allowedSessionStates, [.ready])
    }

    func testReturnsConnectionsResource() async throws {
        let (handler, context) = try await makeContext()
        let response = try await handler.handle(params: nil, context: context)

        guard case .successResponse(let success) = response else {
            XCTFail("Expected success response, got \(response)")
            return
        }

        let resources = success.result["resources"]?.arrayValue
        XCTAssertNotNil(resources)
        let uris = resources?.compactMap { $0["uri"]?.stringValue } ?? []
        XCTAssertTrue(uris.contains("tablepro://connections"))
    }

    func testEntriesIncludeNameAndMimeType() async throws {
        let (handler, context) = try await makeContext()
        let response = try await handler.handle(params: nil, context: context)

        guard case .successResponse(let success) = response,
              let resources = success.result["resources"]?.arrayValue,
              let connections = resources.first(where: { $0["uri"]?.stringValue == "tablepro://connections" })
        else {
            XCTFail("Expected connections resource")
            return
        }

        XCTAssertNotNil(connections["name"]?.stringValue)
        XCTAssertEqual(connections["mimeType"]?.stringValue, "application/json")
    }

    private func makeContext(
        clock: any MCPClock = MCPSystemClock()
    ) async throws -> (ResourcesListHandler, MCPRequestContext) {
        let store = MCPSessionStore(clock: clock)
        let session = try await store.create()
        try await session.transitionToReady()
        let progressSink = StubProgressSink()
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
        let dispatcher = MCPProtocolDispatcher(
            handlers: [ResourcesListHandler(services: services)],
            sessionStore: store,
            progressSink: progressSink,
            clock: clock
        )
        let request = MCPProtocolTestSupport.makeRequest(method: "resources/list")
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
        return (ResourcesListHandler(services: services), context)
    }
}
