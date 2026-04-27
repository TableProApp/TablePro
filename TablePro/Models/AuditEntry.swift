//
//  AuditEntry.swift
//  TablePro
//

import Foundation

enum AuditCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case auth
    case access
    case admin
    case query
    case tool
    case resource

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auth:
            String(localized: "Authentication")
        case .access:
            String(localized: "Access")
        case .admin:
            String(localized: "Administration")
        case .query:
            String(localized: "Query")
        case .tool:
            String(localized: "Tool")
        case .resource:
            String(localized: "Resource")
        }
    }
}

enum AuditOutcome: String, Codable, Sendable {
    case success
    case denied
    case error
    case rateLimited

    var displayName: String {
        switch self {
        case .success:
            String(localized: "Success")
        case .denied:
            String(localized: "Denied")
        case .error:
            String(localized: "Error")
        case .rateLimited:
            String(localized: "Rate limited")
        }
    }
}

struct AuditEntry: Codable, Identifiable, Sendable, Equatable, Hashable {
    let id: UUID
    let timestamp: Date
    let category: AuditCategory
    let tokenId: UUID?
    let tokenName: String?
    let connectionId: UUID?
    let action: String
    let outcome: String
    let details: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: AuditCategory,
        tokenId: UUID? = nil,
        tokenName: String? = nil,
        connectionId: UUID? = nil,
        action: String,
        outcome: String,
        details: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.tokenId = tokenId
        self.tokenName = tokenName
        self.connectionId = connectionId
        self.action = action
        self.outcome = outcome
        self.details = details
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: AuditCategory,
        tokenId: UUID? = nil,
        tokenName: String? = nil,
        connectionId: UUID? = nil,
        action: String,
        outcome: AuditOutcome,
        details: String? = nil
    ) {
        self.init(
            id: id,
            timestamp: timestamp,
            category: category,
            tokenId: tokenId,
            tokenName: tokenName,
            connectionId: connectionId,
            action: action,
            outcome: outcome.rawValue,
            details: details
        )
    }
}
