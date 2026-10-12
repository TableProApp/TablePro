import AppKit
import Foundation

/// How long an Allow lasts, so the prompt can say so rather than guess.
enum MCPApprovalMemory: Sendable, Equatable {
    case thisRequestOnly
    case untilRevoked
}

struct MCPApprovalRequest: Sendable {
    let connectionName: String
    let databaseType: String
    let clientLabel: String?
    let memory: MCPApprovalMemory
}

protocol MCPApprovalPresenting: Sendable {
    func requestApproval(_ request: MCPApprovalRequest) async -> Bool
}

/// The native prompt, and the only one: a client that could answer this question in its own
/// interface could also answer it without asking anyone.
///
/// It carries no deadline. The previous shape raced the alert against a 30 second sleep inside a
/// task group, which could not work: the group cannot propagate the timeout until the uncancellable
/// modal returns, so the request stayed blocked for as long as the alert was up and the user's
/// eventual Allow was thrown away and replaced with a timeout error. Whoever sent the request owns
/// its timeout, which is what the MCP lifecycle says, and an answer is recorded whenever it arrives
/// so that stepping away costs at most the one call.
struct MCPApprovalAlertPresenter: MCPApprovalPresenting {
    func requestApproval(_ request: MCPApprovalRequest) async -> Bool {
        await AlertHelper.runCrossProcessApproval(
            title: String(localized: "MCP Access Request"),
            message: Self.message(for: request),
            confirm: String(localized: "Allow"),
            cancel: String(localized: "Deny")
        )
    }

    static let maximumClientLabelLength = 80

    /// A paired client names itself, at any length, and the connection it wants comes after that
    /// name, so the name is cut short enough for the connection to stay on screen.
    static func message(for request: MCPApprovalRequest) -> String {
        let client = request.clientLabel.map(Self.bounded) ?? String(localized: "An MCP client")
        let opening = String(
            format: String(localized: "%@ wants to access '%@' (%@)."),
            client,
            request.connectionName,
            request.databaseType
        )
        let pointer = String(localized: "Change this in Settings > MCP.")
        return opening + "\n\n" + Self.consequence(of: request.memory) + " " + pointer
    }

    private static func bounded(_ label: String) -> String {
        guard label.count > maximumClientLabelLength else { return label }
        return String(label.prefix(maximumClientLabelLength)) + "…"
    }

    private static func consequence(of memory: MCPApprovalMemory) -> String {
        switch memory {
        case .thisRequestOnly:
            return String(localized: "Allowing covers this request only.")
        case .untilRevoked:
            return String(localized: "Allowing is remembered for this client until you revoke it.")
        }
    }
}
