import Foundation

public enum MCPClientAddress: Sendable, Equatable, Hashable {
    case loopback
    case remote(String)

    public var isLoopback: Bool {
        if case .loopback = self { return true }
        return false
    }

    public var displayValue: String {
        switch self {
        case .loopback:
            return "127.0.0.1"
        case .remote(let host):
            return host
        }
    }
}

public protocol MCPAuthenticator: Sendable {
    func authenticate(
        authorizationHeader: String?,
        clientAddress: MCPClientAddress
    ) async -> MCPAuthDecision
}
