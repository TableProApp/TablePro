import Foundation

public enum MCPSessionEvent: Sendable {
    case created(MCPSessionId)
    case terminated(MCPSessionId, reason: MCPSessionTerminationReason)
}
