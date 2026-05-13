import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("ExecuteQueryTool")
struct ExecuteQueryToolTests {
    @Test("Tool exposes correct metadata")
    func metadata() {
        #expect(ExecuteQueryTool.name == "execute_query")
        #expect(ExecuteQueryTool.requiredScopes == [.toolsRead])
        let schema = ExecuteQueryTool.inputSchema
        let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("connection_id"))
        #expect(required.contains("query"))
    }

    @Test("Multi-statement query is rejected before connection lookup")
    func multiStatementRejected() async throws {
        let tool = ExecuteQueryTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        do {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "query": .string("SELECT 1; SELECT 2")
                ]),
                context: context,
                services: services
            )
            Issue.record("Expected MCPProtocolError for multi-statement query")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("Query exceeding 100KB is rejected with invalidParams")
    func queryTooLargeRejected() async throws {
        let tool = ExecuteQueryTool()
        let context = await MCPProtocolHandlerTestSupport.makeContext(method: "tools/call")
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )
        let oversized = String(repeating: "a", count: 102_401)

        do {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "query": .string(oversized)
                ]),
                context: context,
                services: services
            )
            Issue.record("Expected oversized query to be rejected")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.invalidParams)
        }
    }

    @Test("Cancellation propagates as requestCancelled")
    func cancellationPropagates() async throws {
        let tool = ExecuteQueryTool()
        let progressSink = StubProgressSink()
        let context = await ExecuteQueryToolTestContext.make(
            progressToken: nil,
            progressSink: progressSink
        )
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        await context.cancellation.cancel()

        do {
            _ = try await tool.call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "query": .string("SELECT 1")
                ]),
                context: context,
                services: services
            )
            Issue.record("Expected cancelled error")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.requestCancelled)
        }
    }

    @Test("Progress notifications fire when progressToken is set")
    func progressEmittedWhenTokenPresent() async throws {
        let tool = ExecuteQueryTool()
        let progressSink = StubProgressSink()
        let context = await ExecuteQueryToolTestContext.make(
            progressToken: .string("progress-1"),
            progressSink: progressSink
        )
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        _ = try? await tool.call(
            arguments: .object([
                "connection_id": .string(UUID().uuidString),
                "query": .string("SELECT 1")
            ]),
            context: context,
            services: services
        )

        let methods = await progressSink.methods()
        #expect(methods.allSatisfy { $0 == "notifications/progress" })
        #expect(methods.count >= 1)
    }

    @Test("Progress notifications are skipped when no progressToken")
    func progressSkippedWithoutToken() async throws {
        let tool = ExecuteQueryTool()
        let progressSink = StubProgressSink()
        let context = await ExecuteQueryToolTestContext.make(
            progressToken: nil,
            progressSink: progressSink
        )
        let services = MCPToolServices(
            connectionBridge: MCPConnectionBridge(),
            authPolicy: MCPAuthPolicy()
        )

        _ = try? await tool.call(
            arguments: .object([
                "connection_id": .string(UUID().uuidString),
                "query": .string("SELECT 1")
            ]),
            context: context,
            services: services
        )

        let count = await progressSink.count()
        #expect(count == 0)
    }
}

enum ExecuteQueryToolTestContext {
    static func make(
        progressToken: JsonValue?,
        progressSink: StubProgressSink
    ) async -> MCPRequestContext {
        let sessionStore = MCPSessionStore()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [],
            sessionStore: sessionStore,
            progressSink: progressSink,
            clock: MCPSystemClock()
        )

        let session = MCPSession()
        try? await session.transitionToReady()
        let resolvedSessionId = await session.id

        let principal = MCPProtocolTestSupport.makePrincipal(scopes: [.toolsRead, .toolsWrite])
        let request = JsonRpcRequest(id: .number(1), method: "tools/call", params: nil)
        let (exchange, _) = MCPProtocolTestSupport.makeExchange(
            message: .request(request),
            sessionId: resolvedSessionId,
            principal: principal
        )

        let cancellation = MCPCancellationToken()
        let progress = MCPProgressEmitter(
            progressToken: progressToken,
            target: progressSink,
            sessionId: resolvedSessionId
        )

        return MCPRequestContext(
            exchange: exchange,
            session: session,
            principal: principal,
            dispatcher: dispatcher,
            progress: progress,
            cancellation: cancellation,
            clock: MCPSystemClock()
        )
    }
}
