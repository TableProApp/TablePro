import Foundation

public enum MCPScope: String, Sendable, Equatable, Hashable, CaseIterable {
    case toolsRead = "tools:read"
    case toolsWrite = "tools:write"
    case resourcesRead = "resources:read"
    case admin
}

public struct MCPPrincipalMetadata: Sendable, Equatable {
    public let label: String?
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(label: String?, issuedAt: Date, expiresAt: Date?) {
        self.label = label
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct MCPPrincipal: Sendable, Equatable, Hashable {
    public let tokenFingerprint: String
    public let tokenId: UUID?
    public let scopes: Set<MCPScope>
    public let connectionAccess: ConnectionAccess
    public let metadata: MCPPrincipalMetadata

    public init(
        tokenFingerprint: String,
        tokenId: UUID? = nil,
        scopes: Set<MCPScope>,
        connectionAccess: ConnectionAccess = .all,
        metadata: MCPPrincipalMetadata
    ) {
        self.tokenFingerprint = tokenFingerprint
        self.tokenId = tokenId
        self.scopes = scopes
        self.connectionAccess = connectionAccess
        self.metadata = metadata
    }

    public static func == (lhs: MCPPrincipal, rhs: MCPPrincipal) -> Bool {
        lhs.tokenFingerprint == rhs.tokenFingerprint
            && lhs.tokenId == rhs.tokenId
            && lhs.scopes == rhs.scopes
            && lhs.connectionAccess == rhs.connectionAccess
            && lhs.metadata == rhs.metadata
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(tokenFingerprint)
        hasher.combine(tokenId)
    }
}
