//
//  IntegrationsFormatting.swift
//  TablePro
//

import AppKit
import SwiftUI

enum IntegrationsFormatting {
    static func displayTokenName(_ name: String) -> String {
        name == MCPTokenStore.stdioBridgeTokenName
            ? String(localized: "Built-in CLI")
            : name
    }

    static func outcomeSymbol(_ outcome: AuditOutcome?) -> String {
        switch outcome {
        case .success: "checkmark.circle.fill"
        case .denied, .rateLimited: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .none: "circle.fill"
        }
    }

    static func outcomeTint(_ outcome: AuditOutcome?) -> Color {
        switch outcome {
        case .success: Color(nsColor: .systemGreen)
        case .denied, .rateLimited: Color(nsColor: .systemOrange)
        case .error: Color(nsColor: .systemRed)
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
