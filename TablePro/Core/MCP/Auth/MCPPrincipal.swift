import Foundation

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
    public static let anonymousFingerprint = "anonymous-loopback"

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

    public static let anonymousLoopback = MCPPrincipal(
        tokenFingerprint: anonymousFingerprint,
        tokenId: nil,
        scopes: MCPScope.readOnlySet,
        connectionAccess: .all,
        metadata: MCPPrincipalMetadata(
            label: String(localized: "Anonymous (loopback)"),
            issuedAt: .distantPast,
            expiresAt: nil
        )
    )

    public static let inAppAssistantTokenId = UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")

    public static let inAppAssistant = MCPPrincipal(
        tokenFingerprint: "in-app-assistant",
        tokenId: inAppAssistantTokenId,
        scopes: Set(MCPScope.allCases),
        connectionAccess: .all,
        metadata: MCPPrincipalMetadata(
            label: String(localized: "AI Chat"),
            issuedAt: .distantPast,
            expiresAt: nil
        )
    )

    public var isAnonymous: Bool {
        tokenId == nil
    }

    public var ledgerKey: String {
        guard let tokenId else { return "anon:\(tokenFingerprint)" }
        return tokenId.uuidString
    }

    public var auditLabel: String? {
        metadata.label
    }

    public func has(_ scope: MCPScope) -> Bool {
        scopes.contains(scope)
    }

    public func missingScopes(from required: Set<MCPScope>) -> Set<MCPScope> {
        required.subtracting(scopes)
    }

    public func requireScopes(_ required: Set<MCPScope>, reason: String) throws {
        let missing = missingScopes(from: required)
        guard missing.isEmpty else {
            throw MCPProtocolError.insufficientScope(required: required, reason: reason)
        }
        try requireIssuedToken(for: required, reason: reason)
    }

    public func requireIssuedToken(for required: Set<MCPScope>, reason: String) throws {
        guard isAnonymous else { return }
        let privileged = required.filter(\.requiresIssuedToken)
        guard privileged.isEmpty else {
            throw MCPProtocolError.insufficientScope(required: privileged, reason: reason)
        }
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
