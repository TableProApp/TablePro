import Foundation
import os

public enum MCPEraResolution: Sendable {
    case modern(MCPRequestMeta)
    case legacy(MCPRequestMeta, MCPLegacySessionId)
    case legacyInitialize
}

public actor MCPLegacyEraAdapter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Legacy")

    public static let legacyOnlyMethods: Set<String> = [
        InitializeHandler.method,
        PingHandler.method,
        LegacyLoggingSetLevelHandler.method
    ]

    private let store: MCPLegacySessionStore

    public init(store: MCPLegacySessionStore = MCPLegacySessionStore()) {
        self.store = store
    }

    public static func legacyOnlyHandlers() -> [any MCPMethodHandler] {
        [InitializeHandler(), PingHandler(), LegacyLoggingSetLevelHandler()]
    }

    public static func isLegacyOnly(method: String) -> Bool {
        legacyOnlyMethods.contains(method)
    }

    public func resolve(message: JsonRpcMessage, inbound: MCPInboundContext) async throws -> MCPEraResolution {
        let envelope = Self.envelope(of: message)

        if MCPRequestMeta.declaresModernProtocol(params: envelope.params) {
            let meta = try MCPRequestMeta.decodeModern(params: envelope.params)
            return .modern(meta)
        }

        if envelope.isRequest, envelope.method == InitializeHandler.method {
            return .legacyInitialize
        }

        guard let sessionId = inbound.legacySessionId else {
            throw MCPProtocolError.invalidParams(detail: Self.missingMetaDetail)
        }

        guard let principal = inbound.principal else {
            throw MCPProtocolError.unauthenticated()
        }

        switch await store.lookup(id: sessionId, presentedBy: principal) {
        case .found(let session):
            try Self.validateTransportVersion(
                declared: inbound.transportProtocolVersion,
                negotiated: session.protocolVersion
            )
            let meta = try MCPRequestMeta.synthesizedLegacy(
                protocolVersion: session.protocolVersion,
                clientInfo: session.clientInfo,
                clientCapabilities: session.clientCapabilities,
                params: envelope.params
            )
            return .legacy(meta, sessionId)
        case .principalMismatch:
            Self.logger.error(
                "Legacy session \(sessionId.redacted, privacy: .public) presented by a different principal; refused"
            )
            MCPAuditLogger.logAuthFailure(
                reason: "legacy session presented by a principal that does not own it",
                ip: inbound.clientAddress.displayValue
            )
            throw MCPProtocolError.sessionNotFound()
        case .unknown:
            throw MCPProtocolError.sessionNotFound()
        }
    }

    public func handleInitialize(
        params: JsonValue?,
        principal: MCPPrincipal
    ) async throws -> (MCPResult, MCPLegacySessionId) {
        let negotiated = try InitializeHandler.negotiate(requestedVersion: params?["protocolVersion"]?.stringValue)
        let clientInfo = MCPImplementation(json: params?["clientInfo"])
        let capabilities = MCPClientCapabilities(json: params?["capabilities"] ?? .object([:]))

        let sessionId = await store.establish(
            owner: MCPLegacySessionOwner(principal: principal),
            protocolVersion: negotiated,
            clientInfo: clientInfo,
            clientCapabilities: capabilities
        )

        Self.logger.info(
            "Legacy initialize: client=\(clientInfo?.name ?? "unknown", privacy: .public) version=\(negotiated.rawValue, privacy: .public)"
        )
        return (InitializeHandler.result(protocolVersion: negotiated), sessionId)
    }

    public func terminate(sessionId: MCPLegacySessionId) async {
        await store.terminate(id: sessionId, reason: .clientRequested)
    }

    public func terminateSessions(ownedByTokenId tokenId: UUID) async -> [MCPLegacySessionId] {
        await store.terminateAll(ownedByTokenId: tokenId, reason: .tokenRevoked)
    }

    public func trackInFlight(
        sessionId: MCPLegacySessionId,
        requestId: JsonRpcId,
        cancellation: MCPCancellationToken
    ) async {
        await store.trackInFlight(id: sessionId, requestId: requestId, token: cancellation)
    }

    public func releaseInFlight(sessionId: MCPLegacySessionId, requestId: JsonRpcId) async {
        await store.releaseInFlight(id: sessionId, requestId: requestId)
    }

    public func sessionCount() async -> Int {
        await store.count()
    }

    public func sessionSnapshots() async -> [MCPLegacySessionSnapshot] {
        await store.snapshots()
    }

    public func startIdleSweep() async {
        await store.startIdleSweep()
    }

    public func stopIdleSweep() async {
        await store.stopIdleSweep()
    }

    public func shutdown() async {
        await store.shutdown(reason: .serverShutdown)
    }

    private static let missingMetaDetail = """
    _meta.\(MCPMetaKeys.protocolVersion) and _meta.\(MCPMetaKeys.clientCapabilities) are required, \
    or send initialize first when speaking an initialization-based protocol version
    """

    private static func validateTransportVersion(declared: String?, negotiated: MCPProtocolVersion) throws {
        guard let declared, !declared.isEmpty, declared != negotiated.rawValue else { return }
        throw MCPProtocolError.headerMismatch(
            detail: "MCP-Protocol-Version is \(declared) but this session negotiated \(negotiated.rawValue)"
        )
    }

    private static func envelope(of message: JsonRpcMessage) -> (method: String?, params: JsonValue?, isRequest: Bool) {
        switch message {
        case .request(let request):
            return (request.method, request.params, true)
        case .notification(let notification):
            return (notification.method, notification.params, false)
        case .successResponse, .errorResponse:
            return (nil, nil, false)
        }
    }
}
