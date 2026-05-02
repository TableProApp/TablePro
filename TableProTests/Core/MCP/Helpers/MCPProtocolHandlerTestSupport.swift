import Foundation
@testable import TablePro

enum MCPProtocolHandlerTestSupport {
    static func makeContext(
        method: String,
        params: JsonValue? = nil,
        principalScopes: Set<MCPScope> = [.toolsRead, .toolsWrite],
        requestId: JsonRpcId = .number(1)
    ) async -> MCPRequestContext {
        let sessionStore = MCPSessionStore()
        let progressSink = StubProgressSink()
        let dispatcher = MCPProtocolDispatcher(
            handlers: [],
            sessionStore: sessionStore,
            progressSink: progressSink,
            clock: MCPSystemClock()
        )

        let session = MCPSession()
        try? await session.transitionToReady()

        let principal = MCPProtocolTestSupport.makePrincipal(scopes: principalScopes)
        let request = JsonRpcRequest(id: requestId, method: method, params: params)
        let (exchange, _) = MCPProtocolTestSupport.makeExchange(
            message: .request(request),
            sessionId: session.id,
            principal: principal
        )

        let cancellation = MCPCancellationToken()
        let progress = MCPProgressEmitter(
            progressToken: nil,
            target: progressSink,
            sessionId: session.id
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
