import Foundation

enum LegacyMCPSessionTerminationReason: Sendable, Equatable {
    case removed
    case idleTimeout
    case serverStopped
    case clientDisconnected
}

enum MCPSessionPhase: Sendable, Equatable {
    case created
    case initializing
    case active(tokenId: UUID?, tokenName: String?)
    case terminated(reason: LegacyMCPSessionTerminationReason)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
