import Foundation

enum IntegrationClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case claudeDesktop
    case cursor
    case zed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        }
    }
}
