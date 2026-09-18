import Foundation
import os

public actor MCPProtocolDispatcher {
    internal static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Dispatcher")

    public static let defaultHandlerTimeout: Duration = .seconds(330)
    public static let defaultDisconnectPollInterval: Duration = .seconds(1)

    public static let cacheableMethods: Set<String> = [
        "server/discover",
        "tools/list",
        "prompts/list",
        "resources/list",
        "resources/templates/list",
        "resources/read"
    ]

    public static let inputRequiredMethods: Set<String> = ["prompts/get", "resources/read", "tools/call"]

    public static let deadlineExemptMethods: Set<String> = ["subscriptions/listen"]

    internal static let legacyInitializeMethod = "initialize"
    internal static let legacySessionHeader = "Mcp-Session-Id"
    internal static let cancelledNotificationMethod = "notifications/cancelled"
    internal static let exactDoubleIntegerLimit: Double = 9_007_199_254_740_991

    internal let handlers: [String: any MCPMethodHandler]
    internal let legacyAdapter: MCPLegacyEraAdapter
    internal let activityLedger: MCPClientActivityLedger
    internal let serverInfo: MCPImplementation
    internal let clock: any MCPClock
    internal let handlerTimeout: Duration
    internal let disconnectPollInterval: Duration
    internal let rateLimiter: MCPRateLimiter?
    internal let inflight = MCPInflightRegistry()

    public init(
        handlers: [any MCPMethodHandler],
        legacyAdapter: MCPLegacyEraAdapter,
        activityLedger: MCPClientActivityLedger,
        serverInfo: MCPImplementation,
        clock: any MCPClock = MCPSystemClock(),
        rateLimiter: MCPRateLimiter? = nil,
        handlerTimeout: Duration = MCPProtocolDispatcher.defaultHandlerTimeout,
        disconnectPollInterval: Duration = MCPProtocolDispatcher.defaultDisconnectPollInterval
    ) {
        var map: [String: any MCPMethodHandler] = [:]
        for handler in handlers {
            map[type(of: handler).method] = handler
        }
        self.handlers = map
        self.legacyAdapter = legacyAdapter
        self.activityLedger = activityLedger
        self.serverInfo = serverInfo
        self.clock = clock
        self.rateLimiter = rateLimiter
        self.handlerTimeout = handlerTimeout
        self.disconnectPollInterval = disconnectPollInterval
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

    @discardableResult
    public func cancel(key: MCPInflightKey, reason: MCPCancellationReason) async -> Bool {
        let cancelled = await inflight.cancel(key: key, reason: reason)
        if cancelled {
            Self.logger.debug("Cancelled in-flight request (\(reason.label, privacy: .public))")
        }
        return cancelled
    }

    @discardableResult
    public func cancel(
        requestId: JsonRpcId,
        principal: MCPPrincipal,
        reason: MCPCancellationReason
    ) async -> Bool {
        await cancel(key: MCPInflightKey(principal: principal, requestId: requestId), reason: reason)
    }

    @discardableResult
    public func cancelInflight(matchingTokenId tokenId: UUID) async -> Int {
        let count = await inflight.cancelAll(matchingTokenId: tokenId, reason: .credentialRevoked)
        if count > 0 {
            Self.logger.info("Cancelled \(count, privacy: .public) in-flight request(s) for a revoked token")
        }
        return count
    }

    @discardableResult
    public func cancelAllInflight(reason: MCPCancellationReason = .serverShuttingDown) async -> Int {
        await inflight.cancelAll(reason: reason)
    }

    public func inflightCount() async -> Int {
        await inflight.count()
    }
}
