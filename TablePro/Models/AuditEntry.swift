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

/// What a call to an outside MCP server sent, recorded without recording the payload.
///
/// The bytes and their hash, never the contents. Production rows pass through these calls, and the
/// audit log is plain SQLite with 90-day retention: a copy of every argument the assistant handed a
/// server would be a second store of production data with none of the protections the first one has.
/// The hash is enough to prove two calls were the same and enough to match a call against a server's
/// own log.
struct AuditOutboundDetail: Codable, Sendable, Equatable, Hashable {
    let serverId: UUID
    let serverName: String
    let sessionId: UUID
    let target: String
    let payloadSHA256: String
    let payloadBytes: Int
}

struct AuditEntry: Codable, Identifiable, Sendable, Equatable, Hashable {
    /// Which field list the chain digest covers.
    ///
    /// A row written before the outbound fields existed has to keep verifying, and the digest hashes
    /// an ordered field array, so adding a field to it would report every existing row as tampered.
    /// The version is part of the digest input, so v1 rows verify against the v1 list and v2 rows
    /// against the v2 one, in one database.
    enum SchemaVersion: Int, Codable, Sendable {
        case v1 = 1
        case v2 = 2
    }

    let id: UUID
    let timestamp: Date
    let category: AuditCategory
    let tokenId: UUID?
    let tokenName: String?
    let connectionId: UUID?
    let action: String
    let outcome: String
    let details: String?
    let schemaVersion: SchemaVersion
    let outbound: AuditOutboundDetail?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: AuditCategory,
        tokenId: UUID? = nil,
        tokenName: String? = nil,
        connectionId: UUID? = nil,
        action: String,
        outcome: String,
        details: String? = nil,
        outbound: AuditOutboundDetail? = nil
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
        self.outbound = outbound
        self.schemaVersion = outbound == nil ? .v1 : .v2
    }

    /// Rebuilds a row read from disk under the version it was written with, so verification uses the
    /// same field list the writer did.
    init(
        id: UUID,
        timestamp: Date,
        category: AuditCategory,
        tokenId: UUID?,
        tokenName: String?,
        connectionId: UUID?,
        action: String,
        outcome: String,
        details: String?,
        schemaVersion: SchemaVersion,
        outbound: AuditOutboundDetail?
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
        self.schemaVersion = schemaVersion
        self.outbound = outbound
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
        details: String? = nil,
        outbound: AuditOutboundDetail? = nil
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
            details: details,
            outbound: outbound
        )
    }
}
