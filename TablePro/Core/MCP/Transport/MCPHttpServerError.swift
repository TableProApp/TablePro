import Foundation

public enum MCPHttpServerError: Error, Sendable, Equatable, LocalizedError {
    case tlsRequiredForRemoteAccess
    case alreadyStarted
    case notStarted
    case bindFailed(reason: String)
    case acceptCancelled

    public var errorDescription: String? {
        switch self {
        case .tlsRequiredForRemoteAccess:
            return "Remote access requires TLS to be enabled"
        case .alreadyStarted:
            return "MCP server is already running"
        case .notStarted:
            return "MCP server is not running"
        case .bindFailed(let reason):
            return "Failed to bind MCP server: \(reason)"
        case .acceptCancelled:
            return "MCP server accept loop was cancelled"
        }
    }
}
