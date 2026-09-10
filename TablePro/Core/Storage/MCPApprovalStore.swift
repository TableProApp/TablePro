//
//  MCPApprovalStore.swift
//  TablePro
//

import Foundation
import os

struct MCPConnectionGrant: Codable, Hashable, Sendable, Identifiable {
    let subject: String
    let connectionId: UUID
    let grantedAt: Date

    var id: String { subject + "|" + connectionId.uuidString }
}

struct MCPConnectionDenial: Codable, Hashable, Sendable {
    let subject: String
    let connectionId: UUID
    let expiresAt: Date
}

protocol MCPApprovalStoring: Sendable {
    func grants() async -> [MCPConnectionGrant]
    func record(_ grant: MCPConnectionGrant) async
    func revoke(subject: String, connectionId: UUID) async
    func revokeAll(subject: String) async
    func revokeEverything() async

    func denial(subject: String, connectionId: UUID, now: Date) async -> Date?
    func record(_ denial: MCPConnectionDenial) async
}

/// Durable, revocable MCP connection grants, device-local.
///
/// A grant is a security decision the user made, so it outlives the session that earned it: the
/// server is torn down and rebuilt whenever the port or the authentication toggle changes, and the
/// app is relaunched far more often than that. It is never synced, for the same reason MCP tokens
/// are not.
actor MCPApprovalStore: MCPApprovalStoring {
    static let shared = MCPApprovalStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPApprovalStore")
    private static let grantsKey = "com.TablePro.mcp.connectionGrants"
    private static let denialsKey = "com.TablePro.mcp.connectionDenials"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func grants() -> [MCPConnectionGrant] {
        decode([MCPConnectionGrant].self, forKey: Self.grantsKey)
    }

    func record(_ grant: MCPConnectionGrant) {
        var updated = grants().filter { $0.id != grant.id }
        updated.append(grant)
        encode(updated, forKey: Self.grantsKey)
        Self.logger.info("Remembered an MCP connection grant for \(grant.subject, privacy: .public)")
    }

    func revoke(subject: String, connectionId: UUID) {
        encode(
            grants().filter { !($0.subject == subject && $0.connectionId == connectionId) },
            forKey: Self.grantsKey
        )
    }

    func revokeAll(subject: String) {
        encode(grants().filter { $0.subject != subject }, forKey: Self.grantsKey)
    }

    func revokeEverything() {
        defaults.removeObject(forKey: Self.grantsKey)
    }

    func denial(subject: String, connectionId: UUID, now: Date) -> Date? {
        let surviving = decode([MCPConnectionDenial].self, forKey: Self.denialsKey)
            .filter { $0.expiresAt > now }
        encode(surviving, forKey: Self.denialsKey)
        return surviving.first { $0.subject == subject && $0.connectionId == connectionId }?.expiresAt
    }

    func record(_ denial: MCPConnectionDenial) {
        var updated = decode([MCPConnectionDenial].self, forKey: Self.denialsKey)
            .filter { !($0.subject == denial.subject && $0.connectionId == denial.connectionId) }
        updated.append(denial)
        encode(updated, forKey: Self.denialsKey)
    }

    private func decode<T: Decodable>(_ type: [T].Type, forKey key: String) -> [T] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(type, from: data)
        else { return [] }
        return decoded
    }

    private func encode(_ value: some Encodable & Collection, forKey key: String) {
        guard !value.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value) else {
            Self.logger.error("Failed to encode MCP approvals for \(key, privacy: .public)")
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// Keeps grants for its own lifetime and never writes them anywhere. For tests, and for any path
/// that must not leave a decision on disk.
actor MCPInMemoryApprovalStore: MCPApprovalStoring {
    private var storedGrants: [MCPConnectionGrant] = []
    private var storedDenials: [MCPConnectionDenial] = []

    init() {}

    func grants() -> [MCPConnectionGrant] {
        storedGrants
    }

    func record(_ grant: MCPConnectionGrant) {
        storedGrants.removeAll { $0.id == grant.id }
        storedGrants.append(grant)
    }

    func revoke(subject: String, connectionId: UUID) {
        storedGrants.removeAll { $0.subject == subject && $0.connectionId == connectionId }
    }

    func revokeAll(subject: String) {
        storedGrants.removeAll { $0.subject == subject }
    }

    func revokeEverything() {
        storedGrants.removeAll()
    }

    func denial(subject: String, connectionId: UUID, now: Date) -> Date? {
        storedDenials.removeAll { $0.expiresAt <= now }
        return storedDenials.first { $0.subject == subject && $0.connectionId == connectionId }?.expiresAt
    }

    func record(_ denial: MCPConnectionDenial) {
        storedDenials.removeAll { $0.subject == denial.subject && $0.connectionId == denial.connectionId }
        storedDenials.append(denial)
    }
}
