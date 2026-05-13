import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class PingHandlerTests: XCTestCase {
    func testHandlerMethodIsPing() {
        XCTAssertEqual(PingHandler.method, "ping")
    }

    func testHandlerRequiresNoScopes() {
        XCTAssertTrue(PingHandler.requiredScopes.isEmpty)
    }

    func testHandlerAllowsReadyAndUninitializedStates() {
        XCTAssertTrue(PingHandler.allowedSessionStates.contains(.ready))
    }

    func testReturnsEmptyResult() async throws {
        let (handler, context, _) = try await makeContext()

        let response = try await handler.handle(params: nil, context: context)

        guard case .successResponse(let success) = response else {
            XCTFail("Expected success response, got \(response)")
            return
        }
        XCTAssertEqual(success.result, .object([:]))
    }

    func testTouchesSessionLastActivity() async throws {
        let clock = MCPTestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let (handler, context, session) = try await makeContext(clock: clock)

        let initialActivity = await session.lastActivityAt
        await clock.advance(by: .seconds(120))

        _ = try await handler.handle(params: nil, context: context)

        let after = await session.lastActivityAt
        XCTAssertGreaterThan(after, initialActivity)
        XCTAssertEqual(after, Date(timeIntervalSince1970: 1_700_000_000 + 120))
    }

    private func makeContext(
        clock: any MCPClock = MCPSystemClock()
    ) async throws -> (PingHandler, MCPRequestContext, MCPSession) {
        let store = MCPSessionStore(clock: clock)
        let session = try await store.create()
        let sessionId = await session.id
        let progressSink = StubProgressSink()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [PingHandler()],
            sessionStore: store,
            progressSink: progressSink,
            clock: clock
        )
        let request = MCPProtocolTestSupport.makeRequest(method: "ping")
        let (exchange, _) = MCPProtocolTestSupport.makeExchange(message: request, sessionId: sessionId)
        let token = MCPCancellationToken()
        let emitter = MCPProgressEmitter(
            progressToken: nil,
            target: progressSink,
            sessionId: sessionId
        )
        let context = MCPRequestContext(
            exchange: exchange,
            session: session,
            principal: MCPProtocolTestSupport.makePrincipal(),
            dispatcher: dispatcher,
            progress: emitter,
            cancellation: token,
            clock: clock
        )
        return (PingHandler(), context, session)
    }
}
