import Foundation

enum IntegrationClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case claudeDesktop
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return String(localized: "Claude Code")
        case .claudeDesktop: return String(localized: "Claude Desktop")
        case .cursor: return String(localized: "Cursor")
        }
    }
}
