import Foundation
import TableProPluginKit
@testable import TablePro
import XCTest

final class LoggingSetLevelHandlerTests: XCTestCase {
    func testMethodIsLoggingSetLevel() {
        XCTAssertEqual(LoggingSetLevelHandler.method, "logging/setLevel")
    }

    func testRequiresNoScopes() {
        XCTAssertTrue(LoggingSetLevelHandler.requiredScopes.isEmpty)
    }

    func testAcceptsKnownLevels() async throws {
        for level in ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"] {
            let (handler, context) = try await makeContext()
            let params: JsonValue = .object(["level": .string(level)])
            let response = try await handler.handle(params: params, context: context)

            guard case .successResponse(let success) = response else {
                XCTFail("Expected success response for level \(level)")
                return
            }
            XCTAssertEqual(success.result, .object([:]))
        }
    }

    func testAcceptsUppercaseLevels() async throws {
        let (handler, context) = try await makeContext()
        let params: JsonValue = .object(["level": .string("WARNING")])
        let response = try await handler.handle(params: params, context: context)

        guard case .successResponse = response else {
            XCTFail("Expected success response for uppercase level")
            return
        }
    }

    func testRejectsUnknownLevel() async throws {
        let (handler, context) = try await makeContext()
        let params: JsonValue = .object(["level": .string("verbose")])

        do {
            _ = try await handler.handle(params: params, context: context)
            XCTFail("Expected MCPProtocolError")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        }
    }

    func testRejectsMissingLevel() async throws {
        let (handler, context) = try await makeContext()

        do {
            _ = try await handler.handle(params: .object([:]), context: context)
            XCTFail("Expected MCPProtocolError")
        } catch let error as MCPProtocolError {
            XCTAssertEqual(error.code, JsonRpcErrorCode.invalidParams)
        }
    }

    private func makeContext(
        clock: any MCPClock = MCPSystemClock()
    ) async throws -> (LoggingSetLevelHandler, MCPRequestContext) {
        let store = MCPSessionStore(clock: clock)
        let session = try await store.create()
        try await session.transitionToReady()
        let progressSink = StubProgressSink()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [LoggingSetLevelHandler()],
            sessionStore: store,
            progressSink: progressSink,
            clock: clock
        )
        let request = MCPProtocolTestSupport.makeRequest(method: "logging/setLevel")
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
        return (LoggingSetLevelHandler(), context)
    }
}
