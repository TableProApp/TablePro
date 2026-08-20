import Foundation

public enum MCPScope: String, Sendable, Equatable, Hashable, CaseIterable {
    case toolsRead = "tools:read"
    case toolsWrite = "tools:write"
    case resourcesRead = "resources:read"
    case admin

    public var requiresIssuedToken: Bool {
        switch self {
        case .toolsRead, .resourcesRead:
            return false
        case .toolsWrite, .admin:
            return true
        }
    }

    public static let readOnlySet: Set<MCPScope> = [.toolsRead, .resourcesRead]
    public static let readWriteSet: Set<MCPScope> = [.toolsRead, .toolsWrite, .resourcesRead]
    public static let fullAccessSet: Set<MCPScope> = [.toolsRead, .toolsWrite, .resourcesRead, .admin]
}
