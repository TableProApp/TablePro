import Foundation

public enum MCPSessionState: Sendable, Equatable {
    case initializing
    case ready
    case terminated(reason: MCPSessionTerminationReason)
}

public enum MCPSessionTerminationReason: Sendable, Equatable, CustomStringConvertible {
    case clientRequested
    case idleTimeout
    case capacityEvicted
    case serverShutdown
    case tokenRevoked

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
