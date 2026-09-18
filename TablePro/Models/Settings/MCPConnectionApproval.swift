import Foundation

/// How the MCP server asks before a client may reach a saved connection.
///
/// This is MCP's own decision and is deliberately not `AIConnectionPolicy`. That policy answers a
/// different question, whether a connection's schema may be sent to a model provider, and the
/// connection form describes it as governing in-app AI agents. Both of its controls disappear when
/// AI features are off, which left the MCP prompt with no control at all.
///
/// `alwaysApprove` is the permissive end. `AIConnectionPolicy.never` is the restrictive end of the
/// other policy and still denies here, so the two spellings of "never" never meet.
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
            return String(localized: "The first call asks. The answer is remembered for that client until you revoke it.")
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
