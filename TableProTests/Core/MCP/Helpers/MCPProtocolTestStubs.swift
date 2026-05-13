import Foundation
import TableProPluginKit
@testable import TablePro

actor RecordingResponderSink: MCPResponderSink {
    struct WriteJsonRecord {
        let data: Data
        let status: HttpStatus
        let sessionId: MCPSessionId?
        let extraHeaders: [(String, String)]
    }

    private(set) var jsonWrites: [WriteJsonRecord] = []
    private(set) var acceptedCount: Int = 0
    private(set) var sseHeaderCount: Int = 0
    private(set) var sseFrames: [SseFrame] = []
    private(set) var closed: Bool = false
    private(set) var sseRegistrations: [MCPSessionId] = []

    private var continuation: CheckedContinuation<Void, Never>?
    private var completed: Bool = false

    func writeJson(
        _ data: Data,
        status: HttpStatus,
        sessionId: MCPSessionId?,
        extraHeaders: [(String, String)]
    ) async {
        jsonWrites.append(WriteJsonRecord(
            data: data,
            status: status,
            sessionId: sessionId,
            extraHeaders: extraHeaders
        ))
    }

    func writeAccepted() async {
        acceptedCount += 1
    }

    func writeSseStreamHeaders(sessionId: MCPSessionId) async {
        sseHeaderCount += 1
    }

    func writeSseFrame(_ frame: SseFrame) async {
        sseFrames.append(frame)
    }

    func closeConnection() async {
        closed = true
        if !completed {
            completed = true
            continuation?.resume()
            continuation = nil
        }
    }

    func registerSseConnection(sessionId: MCPSessionId) async {
        sseRegistrations.append(sessionId)
    }

    func waitForCompletion() async {
        if completed { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if completed {
                cont.resume()
                return
            }
            continuation = cont
        }
    }

    func firstJsonMessage() throws -> JsonRpcMessage? {
        guard let record = jsonWrites.first else { return nil }
        return try JsonRpcCodec.decode(record.data)
    }
}

actor StubProgressSink: MCPProgressSink {
    private(set) var notifications: [(notification: JsonRpcNotification, sessionId: MCPSessionId)] = []

    func sendNotification(_ notification: JsonRpcNotification, toSession sessionId: MCPSessionId) async {
        notifications.append((notification, sessionId))
    }

    func count() -> Int {
        notifications.count
    }

    func methods() -> [String] {
        notifications.map(\.notification.method)
    }
}

struct StubMethodHandler: MCPMethodHandler {
    enum Behavior: Sendable {
        case respondImmediately(JsonValue)
        case throwProtocolError(MCPProtocolError)
        case waitForCancellation
        case slowSuccess(milliseconds: UInt64, JsonValue)
    }

    static let method = "test/stub"
    static let requiredScopes: Set<MCPScope> = []
    static let allowedSessionStates: Set<MCPSessionAllowedState> = [.uninitialized, .ready]

    let behavior: Behavior
    let observedCancel: ObservedFlag
    let started: ObservedFlag

    init(behavior: Behavior = .respondImmediately(.object(["ok": .bool(true)]))) {
        self.behavior = behavior
        self.observedCancel = ObservedFlag()
        self.started = ObservedFlag()
    }

    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        await started.set()
        switch behavior {
        case .respondImmediately(let result):
            return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
        case .throwProtocolError(let error):
            throw error
        case .waitForCancellation:
            while true {
                if await context.cancellation.isCancelled() {
                    await observedCancel.set()
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        case .slowSuccess(let ms, let result):
            try await Task.sleep(nanoseconds: ms * 1_000_000)
            return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
        }
    }
}

actor ObservedFlag {
    private var triggered: Bool = false

    func set() {
        triggered = true
    }

    func value() -> Bool {
        triggered
    }
}

struct ConfigurableHandler<T: MCPMethodHandler & Sendable>: MCPMethodHandler {
    static var method: String { T.method }
    static var requiredScopes: Set<MCPScope> { T.requiredScopes }
    static var allowedSessionStates: Set<MCPSessionAllowedState> { T.allowedSessionStates }

    let inner: T

    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        try await inner.handle(params: params, context: context)
    }
}

struct ScopedToolsCallHandler: MCPMethodHandler {
    static let method = "tools/call"
    static let requiredScopes: Set<MCPScope> = [.toolsWrite]
    static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: .object([:]))
    }
}

struct StubToolsListHandler: MCPMethodHandler {
    static let method = "tools/list"
    static let requiredScopes: Set<MCPScope> = []
    static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: .object(["tools": .array([])]))
    }
}

enum MCPProtocolTestSupport {
    static func makePrincipal(scopes: Set<MCPScope> = [.toolsRead, .toolsWrite]) -> MCPPrincipal {
        MCPPrincipal(
            tokenFingerprint: "test-fp",
            scopes: scopes,
            metadata: MCPPrincipalMetadata(
                label: "test",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: nil
            )
        )
    }

    static func makeExchange(
        message: JsonRpcMessage,
        sessionId: MCPSessionId? = nil,
        principal: MCPPrincipal? = nil,
        receivedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> (MCPInboundExchange, RecordingResponderSink) {
        let sink = RecordingResponderSink()
        let requestId: JsonRpcId?
        switch message {
        case .request(let request):
            requestId = request.id
        default:
            requestId = nil
        }
        let responder = MCPExchangeResponder(sink: sink, requestId: requestId)
        let context = MCPInboundContext(
            sessionId: sessionId,
            principal: principal ?? makePrincipal(),
            clientAddress: .loopback,
            receivedAt: receivedAt,
            mcpProtocolVersion: "2025-03-26"
        )
        let exchange = MCPInboundExchange(message: message, context: context, responder: responder)
        return (exchange, sink)
    }

    static func makeRequest(
        id: JsonRpcId = .number(1),
        method: String,
        params: JsonValue? = nil
    ) -> JsonRpcMessage {
        .request(JsonRpcRequest(id: id, method: method, params: params))
    }

    static func makeNotification(method: String, params: JsonValue? = nil) -> JsonRpcMessage {
        .notification(JsonRpcNotification(method: method, params: params))
    }
}
