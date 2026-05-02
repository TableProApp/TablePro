import Foundation
import os

public actor MCPProtocolDispatcher {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Dispatcher")

    private let handlers: [String: any MCPMethodHandler]
    private let sessionStore: MCPSessionStore
    private let progressSink: any MCPProgressSink
    private let clock: any MCPClock
    private let inflight: MCPInflightRegistry

    public init(
        handlers: [any MCPMethodHandler],
        sessionStore: MCPSessionStore,
        progressSink: any MCPProgressSink,
        clock: any MCPClock = MCPSystemClock()
    ) {
        var map: [String: any MCPMethodHandler] = [:]
        for handler in handlers {
            map[type(of: handler).method] = handler
        }
        self.handlers = map
        self.sessionStore = sessionStore
        self.progressSink = progressSink
        self.clock = clock
        self.inflight = MCPInflightRegistry()
    }

    public func dispatch(_ exchange: MCPInboundExchange) async {
        switch exchange.message {
        case .request(let request):
            await handleRequest(request, exchange: exchange)
        case .notification(let notification):
            await handleNotification(notification, exchange: exchange)
        case .successResponse, .errorResponse:
            Self.logger.debug("Ignoring inbound response message")
            await exchange.responder.acknowledgeAccepted()
        }
    }

    public func cancel(requestId: JsonRpcId, sessionId: MCPSessionId) async {
        await inflight.cancel(requestId: requestId, sessionId: sessionId)
    }

    public func cancelInflight(matchingTokenId tokenId: UUID) async -> [MCPSessionId] {
        await inflight.cancelAll(matchingTokenId: tokenId)
    }

    private func handleRequest(_ request: JsonRpcRequest, exchange: MCPInboundExchange) async {
        guard let handler = handlers[request.method] else {
            await respondError(
                exchange: exchange,
                requestId: request.id,
                error: .methodNotFound(method: request.method)
            )
            return
        }

        let session = await resolveOrCreateSession(method: request.method, exchange: exchange)
        guard let session else {
            await respondError(
                exchange: exchange,
                requestId: request.id,
                error: .sessionNotFound()
            )
            return
        }

        let allowed = type(of: handler).allowedSessionStates
        let stateCheck = await checkSessionState(session: session, allowed: allowed)
        if let stateError = stateCheck {
            await respondError(exchange: exchange, requestId: request.id, error: stateError)
            return
        }

        guard let principal = exchange.context.principal else {
            await respondError(
                exchange: exchange,
                requestId: request.id,
                error: .unauthenticated()
            )
            return
        }

        let required = type(of: handler).requiredScopes
        if !required.isEmpty, !required.isSubset(of: principal.scopes) {
            await respondError(
                exchange: exchange,
                requestId: request.id,
                error: .forbidden(reason: "missing required scopes")
            )
            return
        }

        await session.touch(now: await clock.now())
        await session.bindPrincipal(tokenId: principal.tokenId)

        let token = MCPCancellationToken()
        await inflight.register(
            requestId: request.id,
            sessionId: session.id,
            token: token,
            tokenId: principal.tokenId
        )

        let progressToken = MCPProgressEmitter.extractProgressToken(from: request.params)
        let emitter = MCPProgressEmitter(
            progressToken: progressToken,
            target: progressSink,
            sessionId: session.id
        )

        let context = MCPRequestContext(
            exchange: exchange,
            session: session,
            principal: principal,
            dispatcher: self,
            progress: emitter,
            cancellation: token,
            clock: clock
        )

        let response = await invokeHandler(handler, params: request.params, context: context, requestId: request.id)
        await inflight.remove(requestId: request.id, sessionId: session.id)
        await exchange.responder.respond(response, sessionId: session.id)
    }

    private func invokeHandler(
        _ handler: any MCPMethodHandler,
        params: JsonValue?,
        context: MCPRequestContext,
        requestId: JsonRpcId
    ) async -> JsonRpcMessage {
        do {
            return try await handler.handle(params: params, context: context)
        } catch let error as MCPProtocolError {
            return MCPMethodHandlerHelpers.errorResponse(id: requestId, error: error)
        } catch is CancellationError {
            return MCPMethodHandlerHelpers.errorResponse(
                id: requestId,
                error: MCPProtocolError(
                    code: JsonRpcErrorCode.requestCancelled,
                    message: "Request cancelled",
                    httpStatus: .ok
                )
            )
        } catch {
            Self.logger.error("Handler threw error: \(error.localizedDescription, privacy: .public)")
            return MCPMethodHandlerHelpers.errorResponse(
                id: requestId,
                error: .internalError(detail: error.localizedDescription)
            )
        }
    }

    private func handleNotification(_ notification: JsonRpcNotification, exchange: MCPInboundExchange) async {
        if notification.method == "notifications/cancelled" {
            await handleCancellationNotification(notification, exchange: exchange)
            await exchange.responder.acknowledgeAccepted()
            return
        }

        if notification.method == "notifications/initialized" {
            if let sessionId = exchange.context.sessionId,
               let session = await sessionStore.session(id: sessionId) {
                let state = await session.state
                if case .initializing = state {
                    do {
                        try await session.transitionToReady()
                    } catch {
                        Self.logger.warning(
                            "Failed to transition session to ready: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
            await exchange.responder.acknowledgeAccepted()
            return
        }

        await exchange.responder.acknowledgeAccepted()
    }

    private func handleCancellationNotification(
        _ notification: JsonRpcNotification,
        exchange: MCPInboundExchange
    ) async {
        guard let params = notification.params,
              let sessionId = exchange.context.sessionId
        else { return }

        let requestIdValue = params["requestId"]
        let cancelId: JsonRpcId?
        switch requestIdValue {
        case .string(let value):
            cancelId = .string(value)
        case .int(let value):
            cancelId = .number(Int64(value))
        case .double(let value):
            cancelId = .number(Int64(value))
        default:
            cancelId = nil
        }

        guard let cancelId else { return }
        await inflight.cancel(requestId: cancelId, sessionId: sessionId)
    }

    private func resolveOrCreateSession(method: String, exchange: MCPInboundExchange) async -> MCPSession? {
        if method == "initialize" {
            if let sessionId = exchange.context.sessionId,
               let existing = await sessionStore.session(id: sessionId) {
                return existing
            }
            do {
                return try await sessionStore.create()
            } catch {
                Self.logger.warning(
                    "Failed to create session: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }

        guard let sessionId = exchange.context.sessionId else { return nil }
        return await sessionStore.session(id: sessionId)
    }

    private func checkSessionState(
        session: MCPSession,
        allowed: Set<MCPSessionAllowedState>
    ) async -> MCPProtocolError? {
        let state = await session.state
        switch state {
        case .initializing:
            if allowed.contains(.uninitialized) { return nil }
            return .invalidRequest(detail: "Session not initialized")
        case .ready:
            if allowed.contains(.ready) { return nil }
            return .invalidRequest(detail: "Session already initialized")
        case .terminated:
            return .sessionNotFound(message: "Session terminated")
        }
    }

    private func respondError(
        exchange: MCPInboundExchange,
        requestId: JsonRpcId,
        error: MCPProtocolError
    ) async {
        let response = MCPMethodHandlerHelpers.errorResponse(id: requestId, error: error)
        await exchange.responder.respond(response, sessionId: exchange.context.sessionId)
    }
}
