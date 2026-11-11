import Foundation
@testable import TablePro

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
