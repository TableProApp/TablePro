//
//  ConnectionFormPane.swift
//  TablePro
//

import Foundation

enum ConnectionFormPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case ssh
    case ssl
    case customization
    case advanced
    case aiRules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .ssh: return String(localized: "SSH Tunnel")
        case .ssl: return String(localized: "SSL/TLS")
        case .customization: return String(localized: "Customization")
        case .advanced: return String(localized: "Advanced")
        case .aiRules: return String(localized: "AI Rules")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "network"
        case .ssh: return "lock.shield"
        case .ssl: return "lock.fill"
        case .customization: return "paintbrush"
        case .advanced: return "gearshape.2"
        case .aiRules: return "sparkles"
        }
    }

    @MainActor
    func validationBadge(for coordinator: ConnectionFormCoordinator) -> String? {
        let issues: [String]
        switch self {
        case .general:
            issues = coordinator.network.validationIssues + coordinator.auth.validationIssues
        case .ssh:
            issues = coordinator.ssh.validationIssues
        case .ssl:
            issues = coordinator.ssl.validationIssues
        case .customization:
            issues = coordinator.customization.validationIssues
        case .advanced:
            issues = coordinator.advanced.validationIssues
        case .aiRules:
            issues = []
        }
        return issues.isEmpty ? nil : "exclamationmark.triangle.fill"
    }
}
