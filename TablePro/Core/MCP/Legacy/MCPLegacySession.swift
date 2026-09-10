import Foundation

public struct MCPLegacySessionOwner: Sendable, Hashable {
    public let tokenId: UUID?
    public let tokenFingerprint: String

    public init(tokenId: UUID?, tokenFingerprint: String) {
        self.tokenId = tokenId
        self.tokenFingerprint = tokenFingerprint
    }

    public init(principal: MCPPrincipal) {
        self.init(tokenId: principal.tokenId, tokenFingerprint: principal.tokenFingerprint)
    }

    public func owns(_ principal: MCPPrincipal) -> Bool {
        self == MCPLegacySessionOwner(principal: principal)
    }
}

public enum MCPLegacySessionTerminationReason: Sendable, Equatable, CustomStringConvertible {
    case clientRequested
    case idleTimeout
    case capacityEvicted
    case serverShutdown
    case tokenRevoked

    public var cancellationReason: MCPCancellationReason {
        switch self {
        case .clientRequested:
            return .clientRequested(nil)
        case .idleTimeout:
            return .deadlineExceeded
        case .capacityEvicted, .serverShutdown:
            return .serverShuttingDown
        case .tokenRevoked:
            return .credentialRevoked
        }
    }

    public var description: String {
        switch self {
        case .clientRequested:
            return "client_requested"
        case .idleTimeout:
            return "idle_timeout"
        case .capacityEvicted:
            return "capacity_evicted"
        case .serverShutdown:
            return "server_shutdown"
        case .tokenRevoked:
            return "token_revoked"
        }
    }
}

public struct MCPLegacySessionSnapshot: Sendable, Equatable {
    public let id: MCPLegacySessionId
    public let owner: MCPLegacySessionOwner
    public let protocolVersion: MCPProtocolVersion
    public let clientInfo: MCPImplementation?
    public let createdAt: Date
    public let lastActivityAt: Date
    public let inFlightRequestCount: Int

    public init(
        id: MCPLegacySessionId,
        owner: MCPLegacySessionOwner,
        protocolVersion: MCPProtocolVersion,
        clientInfo: MCPImplementation?,
        createdAt: Date,
        lastActivityAt: Date,
        inFlightRequestCount: Int
    ) {
        self.id = id
        self.owner = owner
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.inFlightRequestCount = inFlightRequestCount
    }
}

public struct MCPLegacySession: Sendable {
    public let id: MCPLegacySessionId
    public let owner: MCPLegacySessionOwner
    public let createdAt: Date
    public private(set) var protocolVersion: MCPProtocolVersion
    public private(set) var clientInfo: MCPImplementation?
    public private(set) var clientCapabilities: MCPClientCapabilities
    public private(set) var lastActivityAt: Date

    private var inFlight: [JsonRpcId: MCPCancellationToken]

    public init(
        id: MCPLegacySessionId,
        owner: MCPLegacySessionOwner,
        protocolVersion: MCPProtocolVersion,
        clientInfo: MCPImplementation?,
        clientCapabilities: MCPClientCapabilities,
        createdAt: Date
    ) {
        self.id = id
        self.owner = owner
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.createdAt = createdAt
        lastActivityAt = createdAt
        inFlight = [:]
    }

    public var inFlightRequestCount: Int {
        inFlight.count
    }

    public var snapshot: MCPLegacySessionSnapshot {
        MCPLegacySessionSnapshot(
            id: id,
            owner: owner,
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            inFlightRequestCount: inFlight.count
        )
    }

    public func matchesHandshake(protocolVersion: MCPProtocolVersion, clientInfo: MCPImplementation?) -> Bool {
        self.protocolVersion == protocolVersion && self.clientInfo?.name == clientInfo?.name
    }

    public func isIdle(at cutoff: Date) -> Bool {
        inFlight.isEmpty && lastActivityAt < cutoff
    }

    public mutating func touch(now: Date) {
        lastActivityAt = now
    }

    public mutating func recordHandshake(
        protocolVersion: MCPProtocolVersion,
        clientInfo: MCPImplementation?,
        clientCapabilities: MCPClientCapabilities,
        now: Date
    ) {
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        lastActivityAt = now
    }

    public mutating func trackInFlight(requestId: JsonRpcId, token: MCPCancellationToken) {
        inFlight[requestId] = token
    }

    public mutating func releaseInFlight(requestId: JsonRpcId) {
        inFlight.removeValue(forKey: requestId)
    }

    public mutating func drainInFlight() -> [MCPCancellationToken] {
        let tokens = Array(inFlight.values)
        inFlight.removeAll()
        return tokens
    }
}
