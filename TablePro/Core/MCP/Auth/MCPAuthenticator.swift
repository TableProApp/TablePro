import Foundation

public enum MCPClientAddress: Sendable, Equatable, Hashable {
    case loopback
    case remote(String)
}

public protocol MCPAuthenticator: Sendable {
    func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision
}
