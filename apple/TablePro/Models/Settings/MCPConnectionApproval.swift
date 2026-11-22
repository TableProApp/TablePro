import Foundation

// MCP's own gate. AIConnectionPolicy answers whether a schema may reach a model provider, and its
// controls hide when AI is off, so it cannot be this one. Its "never" still denies here.
enum MCPConnectionApproval: String, Codable, CaseIterable, Identifiable, Sendable {
    case everyTime
    case oncePerConnection
    case alwaysApprove

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everyTime: return String(localized: "Ask Every Time")
        case .oncePerConnection: return String(localized: "Ask Once for Each Connection")
        case .alwaysApprove: return String(localized: "Never Ask")
        }
    }

    var explanation: String {
        switch self {
        case .everyTime:
            return String(localized: "Every call that reaches a connection asks first.")
        case .oncePerConnection:
            return String(localized: "The first call asks. The answer is remembered for that client until you forget it.")
        case .alwaysApprove:
            return String(localized: "Connections are reached without asking.")
        }
    }

    var remembersAnswer: Bool {
        self == .oncePerConnection
    }

    var asksBeforeReachingAConnection: Bool {
        self != .alwaysApprove
    }
}
