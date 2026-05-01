import Foundation

public enum MCPHttpServerError: Error, Sendable, Equatable {
    case tlsRequiredForRemoteAccess
    case alreadyStarted
    case notStarted
    case bindFailed(reason: String)
    case acceptCancelled
}
