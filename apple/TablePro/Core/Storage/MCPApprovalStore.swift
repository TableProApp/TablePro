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

// Device-local and never synced, like MCP tokens. A grant outlives the session because the server is rebuilt on every port change.
actor MCPApprovalStore: MCPApprovalStoring {
    static let shared = MCPApprovalStore()

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPApprovalStore")
    private static let grantsKey = JSONDefaultsKey<[MCPConnectionGrant]>("com.TablePro.mcp.connectionGrants")
    private static let denialsKey = JSONDefaultsKey<[MCPConnectionDenial]>("com.TablePro.mcp.connectionDenials")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    func grants() -> [MCPConnectionGrant] {
        load(Self.grantsKey)
    }

    func record(_ grant: MCPConnectionGrant) {
        var updated = grants().filter { $0.id != grant.id }
        updated.append(grant)
        save(updated, to: Self.grantsKey)
        Self.logger.info("Remembered an MCP connection grant for \(grant.subject, privacy: .public)")
    }

    func revoke(subject: String, connectionId: UUID) {
        save(
            grants().filter { !($0.subject == subject && $0.connectionId == connectionId) },
            to: Self.grantsKey
        )
    }

    func revokeAll(subject: String) {
        save(grants().filter { $0.subject != subject }, to: Self.grantsKey)
    }

    func revokeEverything() {
        defaults.removeValue(for: Self.grantsKey)
    }

    func denial(subject: String, connectionId: UUID, now: Date) -> Date? {
        let surviving = load(Self.denialsKey).filter { $0.expiresAt > now }
        save(surviving, to: Self.denialsKey)
        return surviving.first { $0.subject == subject && $0.connectionId == connectionId }?.expiresAt
    }

    func record(_ denial: MCPConnectionDenial) {
        var updated = load(Self.denialsKey)
            .filter { !($0.subject == denial.subject && $0.connectionId == denial.connectionId) }
        updated.append(denial)
        save(updated, to: Self.denialsKey)
    }

    private func load<Element: Codable>(_ key: JSONDefaultsKey<[Element]>) -> [Element] {
        defaults.read(key).value ?? []
    }

    private func save<Element: Codable>(_ elements: [Element], to key: JSONDefaultsKey<[Element]>) {
        guard !elements.isEmpty else {
            defaults.removeValue(for: key)
            return
        }
        try? defaults.write(elements, to: key)
    }
}
