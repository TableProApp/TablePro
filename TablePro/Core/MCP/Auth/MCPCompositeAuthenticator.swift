import Foundation

public actor MCPCompositeAuthenticator: MCPAuthenticator {
    private let bearer: MCPBearerTokenAuthenticator
    private let requireAuthentication: Bool

    private static let anonymousLoopbackPrincipal = MCPPrincipal(
        tokenFingerprint: "anonymous-loopback",
        tokenId: nil,
        scopes: [.toolsRead, .toolsWrite, .resourcesRead, .admin],
        metadata: MCPPrincipalMetadata(
            label: "Anonymous (loopback)",
            issuedAt: .distantPast,
            expiresAt: nil
        )
    )

    public init(
        bearer: MCPBearerTokenAuthenticator,
        requireAuthentication: Bool
    ) {
        self.bearer = bearer
        self.requireAuthentication = requireAuthentication
    }

    public func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision {
        if !requireAuthentication, case .loopback = clientAddress {
            MCPAuditLogger.logAuthAllowedAnonymous(ip: "127.0.0.1")
            return .allow(Self.anonymousLoopbackPrincipal)
        }
        return await bearer.authenticate(
            authorizationHeader: authorizationHeader,
            clientAddress: clientAddress
        )
    }
}
