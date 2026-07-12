//
//  PrincipalChangeManagerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Principal change manager", .serialized)
@MainActor
struct PrincipalChangeManagerTests {
    private let alice = PluginPrincipalRef(name: "alice")

    private func makeManager() -> PrincipalChangeManager {
        let manager = PrincipalChangeManager()
        manager.load(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog(
                serverPrivileges: [],
                databasePrivileges: [PluginPrivilegeDescriptor(name: "CONNECT", label: "Connect")]
            )
        )
        manager.loadGrants(
            [PluginGrantInfo(privilege: "CONNECT", scope: .database("app"))],
            for: alice
        )
        return manager
    }

    @Test("A freshly loaded principal has no pending changes")
    func startsClean() {
        let manager = makeManager()
        #expect(manager.hasChanges == false)
        #expect(manager.grantChangeSets().isEmpty)
    }

    @Test("Change set is a diff, not a replay of every checkbox")
    func producesDiff() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: .database("app"), for: alice)

        let changeSets = manager.grantChangeSets()
        #expect(changeSets.count == 1)
        #expect(changeSets[0].grantsToAdd.map(\.privilege) == ["CREATE"])
        #expect(changeSets[0].grantsToRemove.isEmpty)
    }

    @Test("Revoking an existing grant produces a removal, not a re-grant")
    func producesRemoval() {
        let manager = makeManager()
        manager.setGranted(false, privilege: "CONNECT", scope: .database("app"), for: alice)

        let changeSets = manager.grantChangeSets()
        #expect(changeSets.count == 1)
        #expect(changeSets[0].grantsToRemove.map(\.privilege) == ["CONNECT"])
        #expect(changeSets[0].grantsToAdd.isEmpty)
    }

    @Test("Toggling back to the original state clears the change")
    func togglingBackIsNoOp() {
        let manager = makeManager()
        manager.setGranted(false, privilege: "CONNECT", scope: .database("app"), for: alice)
        manager.setGranted(true, privilege: "CONNECT", scope: .database("app"), for: alice)

        #expect(manager.grantChangeSets().isEmpty)
        #expect(manager.hasChanges == false)
    }

    @Test("Undo restores the previous grant state")
    func undoRestoresState() {
        let manager = makeManager()
        manager.setGranted(false, privilege: "CONNECT", scope: .database("app"), for: alice)
        #expect(manager.isGranted("CONNECT", scope: .database("app"), for: alice) == false)

        manager.undoManager.undo()
        #expect(manager.isGranted("CONNECT", scope: .database("app"), for: alice) == true)
    }

    @Test("Existing table and column grants round-trip without producing a spurious diff")
    func finerGrainedGrantsRoundTrip() {
        let manager = PrincipalChangeManager()
        let table = PluginPrivilegeScope.table(database: "app", schema: "public", table: "orders")
        let column = PluginPrivilegeScope.column(
            database: "app",
            schema: "public",
            table: "orders",
            column: "total"
        )
        manager.load(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog()
        )
        manager.loadGrants(
            [
                PluginGrantInfo(privilege: "CONNECT", scope: .database("app")),
                PluginGrantInfo(privilege: "SELECT", scope: table),
                PluginGrantInfo(privilege: "UPDATE", scope: column)
            ],
            for: alice
        )

        #expect(manager.grantChangeSets().isEmpty)
        #expect(manager.isGranted("SELECT", scope: table, for: alice))
        #expect(manager.isGranted("UPDATE", scope: column, for: alice))
    }

    @Test("Table and column privileges are editable and diff correctly")
    func editsFinerGrainedGrants() {
        let manager = makeManager()
        let column = PluginPrivilegeScope.column(
            database: "app",
            schema: "public",
            table: "orders",
            column: "total"
        )
        manager.setGranted(true, privilege: "UPDATE", scope: column, for: alice)

        let changeSets = manager.grantChangeSets()
        #expect(changeSets.count == 1)
        #expect(changeSets[0].grantsToAdd.map(\.scope) == [column])
    }

    @Test("A parent scope reports a privilege granted on a descendant")
    func reportsDescendantGrants() {
        let manager = makeManager()
        let column = PluginPrivilegeScope.column(
            database: "app",
            schema: "public",
            table: "orders",
            column: "total"
        )
        manager.setGranted(true, privilege: "UPDATE", scope: column, for: alice)

        #expect(manager.hasDescendantGrant("UPDATE", under: .database("app"), for: alice))
        #expect(manager.hasDescendantGrant("UPDATE", under: .server, for: alice))
        #expect(manager.isGranted("UPDATE", scope: .database("app"), for: alice) == false)
        #expect(manager.hasDescendantGrant("SELECT", under: .database("app"), for: alice) == false)
    }

    @Test("Dropping a principal reports it as losing all access")
    func reportsLockoutRisk() {
        let manager = makeManager()
        manager.stageDrop(alice, options: PluginPrincipalDropOptions())

        #expect(manager.principalsLosingAllAccess().contains(alice))
    }

    @Test("Discard restores the loaded state")
    func discardResets() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: .database("app"), for: alice)
        manager.stageDrop(alice, options: PluginPrincipalDropOptions())

        manager.discardChanges()

        #expect(manager.hasChanges == false)
        #expect(manager.isGranted("CONNECT", scope: .database("app"), for: alice) == true)
        #expect(manager.isGranted("CREATE", scope: .database("app"), for: alice) == false)
    }
}
