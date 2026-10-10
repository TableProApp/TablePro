import Foundation

public enum MCPScope: String, Sendable, Equatable, Hashable, CaseIterable {
    case toolsRead = "tools:read"
    case toolsWrite = "tools:write"
    case resourcesRead = "resources:read"
    case admin
    case connectionsDisplay = "connections:display"

    public var requiresIssuedToken: Bool {
        switch self {
        case .toolsRead, .resourcesRead:
            return false
        case .toolsWrite, .admin, .connectionsDisplay:
            return true
        }
    }

    public static let readOnlySet: Set<MCPScope> = [.toolsRead, .resourcesRead]
    public static let readWriteSet: Set<MCPScope> = [.toolsRead, .toolsWrite, .resourcesRead]
    public static let fullAccessSet: Set<MCPScope> = [.toolsRead, .toolsWrite, .resourcesRead, .admin]

    /// Granted one by one at pairing, never through a permission level, so no tier implies them.
    public static let optionalGrants: Set<MCPScope> = [.connectionsDisplay]
}
