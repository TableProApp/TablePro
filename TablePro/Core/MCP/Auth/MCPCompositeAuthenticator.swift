import Foundation
import os

public actor MCPCompositeAuthenticator: MCPAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Auth")

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
        let presentedCredential = authorizationHeader?.isEmpty == false

        guard !requireAuthentication, clientAddress.isLoopback, !presentedCredential else {
            return await bearer.authenticate(
                authorizationHeader: authorizationHeader,
                clientAddress: clientAddress
            )
        }

        Self.logger.info("Auth allowed anonymously on loopback with no credential presented")
        MCPAuditLogger.logAuthAllowedAnonymous(ip: clientAddress.displayValue)
        return .allow(.anonymousLoopback)
    }
}
