import Foundation

public struct MCPClientInfo: Sendable, Equatable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

public struct MCPSessionSnapshot: Sendable {
    public let id: MCPSessionId
    public let createdAt: Date
    public let lastActivityAt: Date
    public let state: MCPSessionState
    public let clientInfo: MCPClientInfo?

    public init(
        id: MCPSessionId,
        createdAt: Date,
        lastActivityAt: Date,
        state: MCPSessionState,
        clientInfo: MCPClientInfo?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.state = state
        self.clientInfo = clientInfo
    }
}

public enum MCPSessionTransitionError: Error, Sendable, Equatable {
    case illegalTransition(from: MCPSessionState, to: MCPSessionState)
}

public actor MCPSession {
    nonisolated public let id: MCPSessionId
    nonisolated public let createdAt: Date
    public private(set) var lastActivityAt: Date
    public private(set) var state: MCPSessionState
    public private(set) var clientInfo: MCPClientInfo?
    public private(set) var negotiatedProtocolVersion: String?
    public private(set) var clientCapabilities: JsonValue?
    public private(set) var principalTokenId: UUID?

    public init(id: MCPSessionId = .generate(), now: Date = Date()) {
        self.id = id
        self.createdAt = now
        self.lastActivityAt = now
        self.state = .initializing
        self.clientInfo = nil
        self.negotiatedProtocolVersion = nil
        self.clientCapabilities = nil
        self.principalTokenId = nil
    }

    public func touch(now: Date = Date()) {
        guard !isTerminated else { return }
        lastActivityAt = now
    }

    public func bindPrincipal(tokenId: UUID?) {
        guard !isTerminated else { return }
        principalTokenId = tokenId
    }

    public func recordInitialize(
        clientInfo: MCPClientInfo,
        protocolVersion: String,
        capabilities: JsonValue?
    ) {
        self.clientInfo = clientInfo
        self.negotiatedProtocolVersion = protocolVersion
        self.clientCapabilities = capabilities
    }

    public func transitionToReady() throws {
        guard case .initializing = state else {
            throw MCPSessionTransitionError.illegalTransition(from: state, to: .ready)
        }
        state = .ready
    }

    public func terminate(reason: MCPSessionTerminationReason) {
        if case .terminated = state { return }
        state = .terminated(reason: reason)
    }

    public func snapshot() -> MCPSessionSnapshot {
        MCPSessionSnapshot(
            id: id,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            state: state,
            clientInfo: clientInfo
        )
    }

    private var isTerminated: Bool {
        if case .terminated = state { return true }
        return false
    }
}
