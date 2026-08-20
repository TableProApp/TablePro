import Foundation
import os

extension MCPProtocolDispatcher {
    internal func handleRequest(_ request: JsonRpcRequest, exchange: MCPInboundExchange) async {
        let responder = exchange.responder
        let handler = handlers[request.method]
        if handler == nil, request.method != Self.legacyInitializeMethod {
            await responder.respondError(.methodNotFound(method: request.method), requestId: request.id)
            return
        }

        let resolution: MCPEraResolution
        do {
            resolution = try await legacyAdapter.resolve(message: exchange.message, inbound: exchange.context)
        } catch let error as MCPProtocolError {
            await responder.respondError(error, requestId: request.id)
            return
        } catch {
            Self.logger.error("Era resolution failed: \(error.localizedDescription, privacy: .private)")
            await responder.respondError(.internalError(detail: "era resolution failed"), requestId: request.id)
            return
        }

        guard let principal = exchange.context.principal else {
            await responder.respondError(.unauthenticated(), requestId: request.id)
            return
        }

        switch resolution {
        case .legacyInitialize:
            await handleLegacyInitialize(request, principal: principal, exchange: exchange)
        case .modern(let meta):
            guard let handler, type(of: handler).isAvailableToModernClients else {
                await responder.respondError(.methodNotFound(method: request.method), requestId: request.id)
                return
            }
            await runHandler(handler, request: request, meta: meta, principal: principal, exchange: exchange)
        case .legacy(let meta, let sessionId):
            guard let handler, type(of: handler).isAvailableToLegacyClients else {
                await responder.respondError(.methodNotFound(method: request.method), requestId: request.id)
                return
            }
            Self.logger.debug(
                "Legacy \(request.method, privacy: .public) on session \(sessionId.rawValue, privacy: .private)"
            )
            await runHandler(
                handler,
                request: request,
                meta: meta,
                principal: principal,
                exchange: exchange,
                legacySessionId: sessionId
            )
        }
    }

    private func admitted(
        method: String,
        principal: MCPPrincipal,
        address: MCPClientAddress,
        operation: () async -> MCPHandlerOutcome
    ) async -> MCPHandlerOutcome {
        guard let rateLimiter, !Self.deadlineExemptMethods.contains(method) else {
            return await operation()
        }
        let subject: MCPRateLimitSubject = principal.tokenId.map { .token($0) } ?? .address(address)
        do {
            return try await rateLimiter.withRequestSlot(subject: subject) {
                await operation()
            }
        } catch let error as MCPProtocolError {
            return .failure(error)
        } catch {
            return .failure(.serviceUnavailable())
        }
    }

    private func handleLegacyInitialize(
        _ request: JsonRpcRequest,
        principal: MCPPrincipal,
        exchange: MCPInboundExchange
    ) async {
        do {
            let (result, sessionId) = try await legacyAdapter.handleInitialize(
                params: request.params,
                principal: principal
            )
            Self.logger.info("Legacy initialize accepted for session \(sessionId.rawValue, privacy: .private)")
            let payload = result.asJsonValue(era: .legacy, serverInfo: serverInfo)
            await exchange.responder.respond(
                .successResponse(JsonRpcSuccessResponse(id: request.id, result: payload)),
                extraHeaders: [(Self.legacySessionHeader, sessionId.rawValue)]
            )
        } catch let error as MCPProtocolError {
            await exchange.responder.respondError(error, requestId: request.id)
        } catch {
            Self.logger.error("Legacy initialize failed: \(error.localizedDescription, privacy: .private)")
            await exchange.responder.respondError(.internalError(detail: "initialize failed"), requestId: request.id)
        }
    }

    private func runHandler(
        _ handler: any MCPMethodHandler,
        request: JsonRpcRequest,
        meta: MCPRequestMeta,
        principal: MCPPrincipal,
        exchange: MCPInboundExchange,
        legacySessionId: MCPLegacySessionId? = nil
    ) async {
        let responder = exchange.responder
        let required = type(of: handler).requiredScopes
        if !required.isEmpty, !required.isSubset(of: principal.scopes) {
            let scopes = required.map(\.rawValue).sorted().joined(separator: " ")
            await responder.respondError(
                .insufficientScope(required: required, reason: "\(request.method) requires \(scopes)"),
                requestId: request.id
            )
            return
        }

        await activityLedger.record(
            meta: meta,
            principal: principal,
            address: exchange.context.clientAddress,
            at: exchange.context.receivedAt
        )

        let key = MCPInflightKey(principal: principal, requestId: request.id)
        let cancellation = MCPCancellationToken()
        let registered = await inflight.register(
            key: key,
            token: cancellation,
            tokenId: principal.tokenId,
            method: request.method,
            startedAt: exchange.context.receivedAt
        )
        if !registered {
            Self.logger.warning("Client reused an in-flight request id for \(request.method, privacy: .public)")
        }

        let context = MCPRequestContext(
            requestId: request.id,
            params: request.params,
            meta: meta,
            principal: principal,
            responder: responder,
            progress: MCPProgressEmitter(meta: meta, responder: responder),
            cancellation: cancellation,
            clock: clock,
            clientAddress: exchange.context.clientAddress,
            receivedAt: exchange.context.receivedAt
        )

        if let legacySessionId {
            await legacyAdapter.trackInFlight(
                sessionId: legacySessionId,
                requestId: request.id,
                cancellation: cancellation
            )
        }
        let outcome = await admitted(
            method: request.method,
            principal: principal,
            address: exchange.context.clientAddress
        ) {
            await self.execute(handler, request: request, context: context, cancellation: cancellation)
        }
        if let legacySessionId {
            await legacyAdapter.releaseInFlight(sessionId: legacySessionId, requestId: request.id)
        }
        await inflight.remove(key: key, token: cancellation)

        switch outcome {
        case .success(let result):
            guard Self.allowsResultKind(result.kind, method: request.method) else {
                Self.logger.error("\(request.method, privacy: .public) may not ask the client for input")
                await responder.respondError(.internalError(detail: "invalid result"), requestId: request.id)
                return
            }
            let payload = normalize(result, method: request.method, params: request.params)
                .asJsonValue(era: meta.era, serverInfo: serverInfo)
            await responder.respond(.successResponse(JsonRpcSuccessResponse(id: request.id, result: payload)))
        case .failure(let error):
            await responder.respondError(error, requestId: request.id)
        }
    }

    private func execute(
        _ handler: any MCPMethodHandler,
        request: JsonRpcRequest,
        context: MCPRequestContext,
        cancellation: MCPCancellationToken
    ) async -> MCPHandlerOutcome {
        let gate = MCPHandlerOutcomeGate()
        let method = request.method
        let params = request.params

        let work = Task {
            let outcome: MCPHandlerOutcome
            do {
                outcome = .success(try await handler.handle(params: params, context: context))
            } catch let error as MCPProtocolError {
                outcome = .failure(error)
            } catch is CancellationError {
                outcome = .failure(.requestCancelled())
            } catch {
                Self.logger.error(
                    "Handler \(method, privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
                )
                outcome = .failure(.internalError(detail: "handler failed"))
            }
            await gate.settle(outcome)
        }
        await cancellation.onCancel { _ in work.cancel() }

        let watchdog = makeWatchdog(
            method: method,
            responder: context.responder,
            cancellation: cancellation,
            gate: gate
        )

        let outcome = await gate.wait()
        watchdog.cancel()
        work.cancel()
        return outcome
    }

    private func makeWatchdog(
        method: String,
        responder: MCPResponder,
        cancellation: MCPCancellationToken,
        gate: MCPHandlerOutcomeGate
    ) -> Task<Void, Never> {
        let watchdogClock = clock
        let pollInterval = disconnectPollInterval
        let deadline: Duration? = Self.deadlineExemptMethods.contains(method) ? nil : handlerTimeout

        return Task {
            var elapsed = Duration.zero
            while true {
                let remaining = deadline.map { $0 - elapsed }
                if let remaining, remaining <= .zero { break }
                let step = remaining.map { min(pollInterval, $0) } ?? pollInterval
                do {
                    try await watchdogClock.sleep(for: step)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                elapsed += step
                guard await responder.clientDisconnected() else { continue }
                Self.logger.debug("Client disconnected during \(method, privacy: .public)")
                await cancellation.cancel(reason: .clientDisconnected)
                await gate.settle(.failure(.requestCancelled()))
                return
            }
            Self.logger.error("Handler \(method, privacy: .public) exceeded its deadline")
            await cancellation.cancel(reason: .deadlineExceeded)
            await gate.settle(.failure(.requestTimeout(detail: "\(method) exceeded the handler deadline")))
        }
    }

    private func normalize(_ result: MCPResult, method: String, params: JsonValue?) -> MCPResult {
        guard result.kind == .complete, Self.cacheableMethods.contains(method) else {
            guard result.cacheHint != nil else { return result }
            Self.logger.warning("Dropping a cache hint \(method, privacy: .public) may not carry")
            return replacingCacheHint(in: result, with: nil)
        }
        if Self.carriesInputResponses(params: params) {
            return replacingCacheHint(in: result, with: .uncacheable)
        }
        guard result.cacheHint == nil else { return result }
        Self.logger.warning("\(method, privacy: .public) returned no cache hint; treating it as uncacheable")
        return replacingCacheHint(in: result, with: .uncacheable)
    }

    private func replacingCacheHint(in result: MCPResult, with hint: MCPCacheHint?) -> MCPResult {
        MCPResult(kind: result.kind, payload: result.payload, cacheHint: hint, meta: result.meta)
    }

    private static func allowsResultKind(_ kind: MCPResult.Kind, method: String) -> Bool {
        kind == .complete || Self.inputRequiredMethods.contains(method)
    }

    private static func carriesInputResponses(params: JsonValue?) -> Bool {
        guard let params else { return false }
        let inputResponses = params["inputResponses"]
        let requestState = params["requestState"]
        return inputResponses?.isNull == false || requestState?.isNull == false
    }
}

private enum MCPHandlerOutcome: Sendable {
    case success(MCPResult)
    case failure(MCPProtocolError)
}

private actor MCPHandlerOutcomeGate {
    private var settled: MCPHandlerOutcome?
    private var waiter: CheckedContinuation<MCPHandlerOutcome, Never>?
    private var delivered = false

    func settle(_ outcome: MCPHandlerOutcome) {
        guard !delivered else { return }
        guard let continuation = waiter else {
            if settled == nil {
                settled = outcome
            }
            return
        }
        waiter = nil
        delivered = true
        continuation.resume(returning: outcome)
    }

    func wait() async -> MCPHandlerOutcome {
        if let settled {
            delivered = true
            return settled
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
