import AppKit
import SwiftUI
import TableProMCP

enum IntegrationsFormatting {
    // MCPTokenStore keeps both reserved names for TablePro's own tokens, at mint and at load, so a paired
    // client cannot borrow these labels.
    static func displayTokenName(_ name: String) -> String {
        switch name {
        case MCPTokenStore.stdioBridgeTokenName:
            String(localized: "Built-in CLI")
        case MCPTokenStore.claudeAgentTokenName:
            AIProviderType.claudeAgent.displayName
        default:
            name
        }
    }

    // The tablepro command names itself "Command Line"; the window calls it what Settings calls it.
    static func displayClientName(_ client: MCPServerManager.SessionSnapshot) -> String {
        client.clientInfoName == CLIClientIdentity.name
            ? String(localized: "tablepro command")
            : client.clientName
    }

    static func outcomeSymbol(_ outcome: AuditOutcome?) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .denied, .rateLimited: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .none: "questionmark.circle"
        }
    }

    static func outcomeTint(_ outcome: AuditOutcome?) -> Color {
        switch outcome {
        case .success: .green
        case .denied, .rateLimited: .orange
        case .error: .red
        case .none: Color(nsColor: .secondaryLabelColor)
        }
    }

    static func outcomeSeverity(_ outcome: AuditOutcome?) -> Int {
        switch outcome {
        case .error: 0
        case .rateLimited: 1
        case .denied: 2
        case .success: 3
        case .none: 4
        }
    }
}

extension AuditEntry {
    var outcomeSeverity: Int {
        IntegrationsFormatting.outcomeSeverity(AuditOutcome(rawValue: outcome))
    }
}
