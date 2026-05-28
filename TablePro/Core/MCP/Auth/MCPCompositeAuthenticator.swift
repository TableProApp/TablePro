import Foundation

public actor MCPCompositeAuthenticator: MCPAuthenticator {
    private let bearer: MCPBearerTokenAuthenticator
    private let requireAuthentication: Bool

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
            return .allow(MCPPrincipal.anonymousLoopback)
        }
        return await bearer.authenticate(
            authorizationHeader: authorizationHeader,
            clientAddress: clientAddress
        )
    }
}
