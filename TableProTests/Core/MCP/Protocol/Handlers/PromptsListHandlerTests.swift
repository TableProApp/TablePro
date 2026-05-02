import Foundation
@testable import TablePro
import XCTest

final class PromptsListHandlerTests: XCTestCase {
    func testMethodIsPromptsList() {
        XCTAssertEqual(PromptsListHandler.method, "prompts/list")
    }

    func testRequiresNoScopes() {
        XCTAssertTrue(PromptsListHandler.requiredScopes.isEmpty)
    }

    func testAllowedInReadyState() {
        XCTAssertEqual(PromptsListHandler.allowedSessionStates, [.ready])
    }

    func testReturnsEmptyList() async throws {
        let (handler, context) = try await makeContext()
        let response = try await handler.handle(params: nil, context: context)

        guard case .successResponse(let success) = response else {
            XCTFail("Expected success response, got \(response)")
            return
        }

        XCTAssertEqual(success.result, .object(["prompts": .array([])]))
    }

    private func makeContext(
        clock: any MCPClock = MCPSystemClock()
    ) async throws -> (PromptsListHandler, MCPRequestContext) {
        let store = MCPSessionStore(clock: clock)
        let session = try await store.create()
        try await session.transitionToReady()
        let progressSink = StubProgressSink()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [PromptsListHandler()],
            sessionStore: store,
            progressSink: progressSink,
            clock: clock
        )
        let request = MCPProtocolTestSupport.makeRequest(method: "prompts/list")
        let principal = MCPProtocolTestSupport.makePrincipal(scopes: [])
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
        return (PromptsListHandler(), context)
    }
}
