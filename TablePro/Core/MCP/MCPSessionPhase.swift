import Foundation

enum MCPSessionPhase: Sendable, Equatable {
    case created
    case initializing
    case active(tokenId: UUID?, tokenName: String?)
    case terminated(reason: String)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}
