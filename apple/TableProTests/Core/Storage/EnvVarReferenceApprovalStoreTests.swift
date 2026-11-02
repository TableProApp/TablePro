//
//  EnvVarReferenceApprovalStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class SavedLibrary {
    var rows: [DatabaseConnection]?
}

@MainActor
struct EnvVarReferenceApprovalStoreTests {
    private let suite: EphemeralDefaults
    private let defaults: UserDefaults

    init() throws {
        suite = try EphemeralDefaults()
        defaults = suite.defaults
    }

    private func makeStore(saved: @escaping @MainActor () -> [DatabaseConnection]? = { [] }) -> EnvVarReferenceApprovalStore {
        EnvVarReferenceApprovalStore(defaults: defaults, savedConnections: saved)
    }

    private func referencing(
        id: UUID = UUID(),
        host: String = "db.internal.example",
        username: String = "$DB_USER",
        origin: ConnectionOrigin = .thisMac
    ) -> DatabaseConnection {
        var connection = DatabaseConnection(
            id: id,
            name: "Orders",
            host: host,
            port: 5_432,
            database: "${DB_NAME}",
            username: username,
            type: .postgresql
        )
        connection.origin = origin
        return connection
    }

    @Test("Nothing is approved until someone approves it")
    func nothingApprovedByDefault() {
        #expect(!makeStore().isApproved(referencing()))
    }

    @Test("A connection with no references needs no approval")
    func noReferencesNeedsNothing() {
        #expect(makeStore().isApproved(DatabaseConnection(name: "Plain", host: "db.example.com", username: "app")))
    }

    @Test("An approval covers its connection only")
    func approvalIsPerConnection() {
        let store = makeStore()
        let approved = referencing()
        store.approveReferences(of: approved)

        #expect(store.isApproved(approved))
        #expect(!store.isApproved(referencing()))
    }

    @Test("An approval covers the destination it was given for, not a renamed field")
    func approvalIsBoundToTheDestination() {
        let store = makeStore()
        var connection = referencing()
        store.approveReferences(of: connection)

        connection.name = "Orders (renamed)"
        connection.database = "$DB_USER"
        #expect(store.isApproved(connection))

        connection.port = 6_432
        #expect(!store.isApproved(connection))

        connection.port = 5_432
        connection.host = "db.attacker.example"
        #expect(!store.isApproved(connection))
    }

    @Test("An approval covers the names it was given for, and fewer of them")
    func approvalIsBoundToTheNames() {
        let store = makeStore()
        var connection = referencing()
        store.approveReferences(of: connection)

        connection.database = "orders"
        #expect(store.isApproved(connection))

        connection.username = "$DB_USER$AWS_SECRET_ACCESS_KEY"
        #expect(!store.isApproved(connection))
    }

    @Test("Approving another destination keeps the earlier one")
    func approvalsAccumulatePerDestination() {
        let store = makeStore()
        let id = UUID()
        let first = referencing(id: id, host: "db1.internal.example")
        let second = referencing(id: id, host: "db2.internal.example")
        store.approveReferences(of: first)
        store.approveReferences(of: second)

        #expect(store.isApproved(first))
        #expect(store.isApproved(second))
    }

    @Test("Revoking forgets a connection's approvals and keeps the others")
    func revokeIsScoped() {
        let store = makeStore()
        let deleted = referencing()
        let kept = referencing()
        store.approveReferences(of: deleted)
        store.approveReferences(of: kept)

        store.revoke(for: deleted.id)

        #expect(!store.isApproved(deleted))
        #expect(store.isApproved(kept))
    }

    @Test("A duplicate takes the approvals of the connection it copies")
    func copyCarriesApprovals() {
        let store = makeStore()
        let source = referencing()
        let duplicate = referencing()
        store.approveReferences(of: source)

        store.copyApprovals(from: source.id, to: duplicate.id)

        #expect(store.isApproved(duplicate))
    }

    @Test("Approvals persist in the defaults they were written to")
    func persists() {
        let connection = referencing()
        makeStore().approveReferences(of: connection)

        #expect(makeStore().isApproved(connection))
    }

    @Test("The first use approves rows this Mac made, and never an imported or synced one")
    func migrationTrustsOnlyThisMacRows() {
        let own = referencing()
        let imported = referencing(host: "pg.attacker.example", origin: .imported)
        let synced = referencing(origin: .synced)
        let store = makeStore { [own, imported, synced] }

        #expect(store.isApproved(own))
        #expect(!store.isApproved(imported))
        #expect(!store.isApproved(synced))
    }

    @Test("The migration runs once, so a row it did not see, or saw in an untrusted file, stays unapproved")
    func migrationRunsOnce() {
        let later = referencing()
        #expect(!makeStore { [] }.isApproved(referencing()))

        #expect(!makeStore { [later] }.isApproved(later))
    }

    @Test("The migration waits while the library cannot be read")
    func migrationWaitsForAReadableLibrary() {
        let own = referencing()
        let library = SavedLibrary()
        let store = makeStore { library.rows }

        #expect(!store.isApproved(own))
        library.rows = [own]
        #expect(store.isApproved(own))
    }
}
