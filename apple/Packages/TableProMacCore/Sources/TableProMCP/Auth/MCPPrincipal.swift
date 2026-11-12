import Foundation

public struct MCPPrincipalMetadata: Sendable, Equatable {
    public let label: String?
    public let issuedAt: Date
    public let expiresAt: Date?
    public let isBridgeCredential: Bool
    public let isClaudeAgentCredential: Bool

    public init(
        label: String?,
        issuedAt: Date,
        expiresAt: Date?,
        isBridgeCredential: Bool = false,
        isClaudeAgentCredential: Bool = false
    ) {
        self.label = label
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.isBridgeCredential = isBridgeCredential
        self.isClaudeAgentCredential = isClaudeAgentCredential
    }
}

public struct MCPPrincipal: Sendable, Equatable, Hashable {
    public let tokenFingerprint: String
    public let tokenId: UUID
    public let scopes: Set<MCPScope>
    public let connectionAccess: ConnectionAccess
    public let metadata: MCPPrincipalMetadata
    // Nil means every tool the scopes allow.
    public let toolAllowlist: Set<String>?

    public init(
        tokenFingerprint: String,
        tokenId: UUID,
        scopes: Set<MCPScope>,
        connectionAccess: ConnectionAccess = .all,
        metadata: MCPPrincipalMetadata,
        toolAllowlist: Set<String>? = nil
    ) {
        self.tokenFingerprint = tokenFingerprint
        self.tokenId = tokenId
        self.scopes = scopes
        self.connectionAccess = connectionAccess
        self.metadata = metadata
        self.toolAllowlist = toolAllowlist
    }

    public static let inAppAssistantTokenId = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xA1, 0x1A))

    public static let inAppAssistant = MCPPrincipal(
        tokenFingerprint: "in-app-assistant",
        tokenId: inAppAssistantTokenId,
        scopes: MCPScope.fullAccessSet,
        connectionAccess: .all,
        metadata: MCPPrincipalMetadata(
            label: String(localized: "AI Chat"),
            issuedAt: .distantPast,
            expiresAt: nil
        )
    )

    public var ledgerKey: String {
        tokenId.uuidString
    }

    public var auditLabel: String? {
        metadata.label
    }

    public func has(_ scope: MCPScope) -> Bool {
        scopes.contains(scope)
    }

    public func allowsTool(_ name: String) -> Bool {
        toolAllowlist?.contains(name) ?? true
    }

    public func missingScopes(from required: Set<MCPScope>) -> Set<MCPScope> {
        required.subtracting(scopes)
    }

    public func requireScopes(_ required: Set<MCPScope>, reason: String) throws {
        let missing = missingScopes(from: required)
        guard missing.isEmpty else {
            throw MCPProtocolError.insufficientScope(required: required, reason: reason)
        }
    }

    public static func == (lhs: MCPPrincipal, rhs: MCPPrincipal) -> Bool {
        lhs.tokenFingerprint == rhs.tokenFingerprint
            && lhs.tokenId == rhs.tokenId
            && lhs.scopes == rhs.scopes
            && lhs.connectionAccess == rhs.connectionAccess
            && lhs.metadata == rhs.metadata
            && lhs.toolAllowlist == rhs.toolAllowlist
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(tokenFingerprint)
        hasher.combine(tokenId)
    }
}
