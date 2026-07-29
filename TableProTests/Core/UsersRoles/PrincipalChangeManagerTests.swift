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
    private let app = PluginPrivilegeScope.database("app")

    private func makeManager() -> PrincipalChangeManager {
        let manager = PrincipalChangeManager()
        manager.load(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog(
                databasePrivileges: [
                    PluginPrivilegeDescriptor(name: "CONNECT", label: "Connect"),
                    PluginPrivilegeDescriptor(name: "CREATE", label: "Create")
                ]
            )
        )
        manager.loadGrants(
            [PluginGrantInfo(privilege: "CONNECT", scope: .database("app"), isGrantable: true)],
            for: alice
        )
        return manager
    }

    @Test("A freshly loaded principal has no pending changes")
    func startsClean() {
        let manager = makeManager()
        #expect(manager.hasChanges == false)
        #expect(manager.changeCount == 0)
    }

    @Test("Granting produces an add, revoking produces a remove")
    func producesDiff() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: app, for: alice)

        let sets = manager.grantChangeSets()
        #expect(sets.count == 1)
        #expect(sets[0].grantsToAdd.map(\.privilege) == ["CREATE"])
        #expect(sets[0].grantsToRemove.isEmpty)
        #expect(manager.changeCount == 1)
    }

    @Test("Toggling back to the baseline clears the change entirely")
    func togglingBackIsNoOp() {
        let manager = makeManager()
        manager.setGranted(false, privilege: "CONNECT", scope: app, for: alice)
        #expect(manager.changeCount == 1)

        manager.setGranted(true, privilege: "CONNECT", scope: app, for: alice)
        #expect(manager.grantChangeSets().isEmpty)
        #expect(manager.changeCount == 0)
    }

    @Test("Re-granting a baseline grant never strips its grant option")
    func preservesGrantOption() {
        let manager = makeManager()
        manager.setGranted(false, privilege: "CONNECT", scope: app, for: alice)
        manager.setGranted(true, privilege: "CONNECT", scope: app, for: alice)

        #expect(manager.grantChangeSets().isEmpty)
        #expect(manager.isGrantable("CONNECT", scope: app, for: alice))
    }

    @Test("A staged grant carries the grant option from the baseline")
    func rebuildsGrantOption() {
        let manager = makeManager()
        manager.setGranted(false, privilege: "CONNECT", scope: app, for: alice)

        let removed = manager.grantChangeSets().first?.grantsToRemove.first
        #expect(removed?.isGrantable == true)
    }

    @Test("Reload rebases and drops intent the server already satisfies")
    func reloadRebases() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: app, for: alice)
        #expect(manager.changeCount == 1)

        manager.reload(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog(
                databasePrivileges: [PluginPrivilegeDescriptor(name: "CREATE", label: "Create")]
            )
        )
        manager.loadGrants(
            [
                PluginGrantInfo(privilege: "CONNECT", scope: app),
                PluginGrantInfo(privilege: "CREATE", scope: app)
            ],
            for: alice
        )

        #expect(manager.changeCount == 0)
        #expect(manager.isGranted("CREATE", scope: app, for: alice))
    }

    @Test("Reload drops the stale grant baseline so it is refetched from the server")
    func reloadInvalidatesGrantBaseline() {
        let manager = makeManager()
        #expect(manager.hasLoadedGrants(for: alice))

        manager.reload(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog()
        )

        // If the baseline survived, loadGrants would skip the refetch and a privilege applied this
        // session would render unchecked and could never be revoked.
        #expect(manager.hasLoadedGrants(for: alice) == false)
    }

    @Test("Reload keeps the seeded baseline of a staged create, which has nothing to fetch")
    func reloadKeepsStagedCreateBaseline() {
        let carol = PluginPrincipalRef(name: "carol")
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: carol))

        manager.reload(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog()
        )

        #expect(manager.hasLoadedGrants(for: carol))
        #expect(manager.stage(of: carol) == .created)
    }

    @Test("Reload drops a delta for a principal that no longer exists on the server")
    func reloadDropsDeadDeltas() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: app, for: alice)
        #expect(manager.changeCount == 1)

        manager.reload(principals: [], catalog: PluginPrivilegeCatalog())

        #expect(manager.changeCount == 0)
        #expect(manager.grantChangeSets().isEmpty)
    }

    @Test("An attribute edit on a staged create folds into the CREATE instead of a dropped ALTER")
    func foldsAlterIntoStagedCreate() {
        let carol = PluginPrincipalRef(name: "carol")
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: carol, canLogin: true))

        manager.stageAlter(
            PluginPrincipalDefinition(ref: carol, canLogin: false),
            for: carol
        )

        let changes = manager.pendingChanges()
        #expect(changes.count == 1)
        guard case let .create(definition) = changes[0] else {
            Issue.record("expected a single create carrying the edit")
            return
        }
        #expect(definition.canLogin == false)
    }

    @Test("Removing a staged create takes its password and grants with it")
    func unstageCreateClearsEverything() {
        let carol = PluginPrincipalRef(name: "carol")
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: carol))
        manager.stageSetPassword("secret", for: carol)
        manager.setGranted(true, privilege: "CONNECT", scope: app, for: carol)

        manager.unstageCreate(carol)

        #expect(manager.changeCount == 0)
        #expect(manager.pendingChanges().isEmpty)
    }

    @Test("Each mutation is its own undo group, independent of run-loop timing")
    func undoIsPerMutation() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: app, for: alice)
        manager.stageDrop(PluginPrincipalRef(name: "bob"), options: PluginPrincipalDropOptions())
        #expect(manager.changeCount == 2)

        // With NSUndoManager's default groupsByEvent, both registrations would coalesce into one
        // run-loop group and a single undo would reverse both.
        manager.undoManager.undo()
        #expect(manager.changeCount == 1)
        #expect(manager.isGranted("CREATE", scope: app, for: alice))

        manager.undoManager.undo()
        #expect(manager.changeCount == 0)
    }

    @Test("A bulk grant is a single undo group")
    func bulkGrantIsOneUndoGroup() {
        let manager = makeManager()
        manager.setGranted(
            true,
            privileges: ["CONNECT", "CREATE"],
            scopes: [app, .database("other")],
            for: alice
        )
        #expect(manager.changeCount > 1)

        manager.undoManager.undo()
        #expect(manager.changeCount == 0)
    }

    @Test("Undoing the removal of a staged create restores its grants")
    func undoUnstageCreateRestoresGrants() {
        let carol = PluginPrincipalRef(name: "carol")
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: carol))
        manager.setGranted(true, privilege: "CONNECT", scope: app, for: carol)

        manager.unstageCreate(carol)
        manager.undoManager.undo()

        #expect(manager.stage(of: carol) == .created)
        #expect(manager.isGranted("CONNECT", scope: app, for: carol))
    }

    @Test("Reload preserves intent the server has not satisfied")
    func reloadPreservesIntent() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: app, for: alice)

        manager.reload(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog()
        )
        manager.loadGrants([PluginGrantInfo(privilege: "CONNECT", scope: app)], for: alice)

        #expect(manager.changeCount == 1)
        #expect(manager.isGranted("CREATE", scope: app, for: alice))
    }

    @Test("Undo restores the previous grant state")
    func undoRestoresState() {
        let manager = makeManager()
        manager.setGranted(false, privilege: "CONNECT", scope: app, for: alice)
        #expect(manager.isGranted("CONNECT", scope: app, for: alice) == false)

        manager.undoManager.undo()
        #expect(manager.isGranted("CONNECT", scope: app, for: alice))
        #expect(manager.changeCount == 0)
    }

    @Test("A no-op alter is never staged")
    func dropsNoOpAlter() {
        let info = PluginPrincipalInfo(ref: alice)
        let manager = PrincipalChangeManager()
        manager.load(principals: [info], catalog: PluginPrivilegeCatalog())

        manager.stageAlter(PrincipalChangeManager.definition(from: info), for: alice)
        #expect(manager.changeCount == 0)
        #expect(manager.pendingChanges().isEmpty)
    }

    @Test("A real alter is staged and reaches the change list")
    func stagesAlter() {
        let info = PluginPrincipalInfo(ref: alice, canLogin: true)
        let manager = PrincipalChangeManager()
        manager.load(principals: [info], catalog: PluginPrivilegeCatalog())

        manager.stageAlter(
            PluginPrincipalDefinition(ref: alice, canLogin: false),
            for: alice
        )
        #expect(manager.changeCount == 1)
        #expect(manager.stage(of: alice) == .modified)
    }

    @Test("Copying privileges stages the source's grants on the target")
    func copiesGrants() {
        let bob = PluginPrincipalRef(name: "bob")
        let manager = makeManager()
        manager.loadGrants([], for: bob)

        manager.copyGrants(from: alice, to: bob)

        #expect(manager.isGranted("CONNECT", scope: app, for: bob))
        #expect(manager.changeCount == 1)
    }

    @Test("Dropping the connected account is reported as self-impact")
    func reportsSelfImpact() {
        let manager = makeManager()
        manager.stageDrop(alice, options: PluginPrincipalDropOptions())

        #expect(manager.selfImpact(connected: alice) != nil)
        #expect(manager.selfImpact(connected: PluginPrincipalRef(name: "other")) == nil)
    }

    @Test("Granted scope closure includes every ancestor of a grant")
    func buildsScopeClosure() {
        let manager = makeManager()
        let column = PluginPrivilegeScope.column(
            database: "app",
            schema: "public",
            table: "orders",
            column: "total"
        )
        manager.setGranted(true, privilege: "UPDATE", scope: column, for: alice)

        let closure = manager.grantedScopeClosure(for: alice)
        #expect(closure.contains(column))
        #expect(closure.contains(.table(database: "app", schema: "public", table: "orders")))
        #expect(closure.contains(.schema(database: "app", schema: "public")))
        #expect(closure.contains(.database("app")))
        #expect(closure.contains(.server))
    }

    @Test("Discard restores the loaded state")
    func discardResets() {
        let manager = makeManager()
        manager.setGranted(true, privilege: "CREATE", scope: app, for: alice)
        manager.stageDrop(alice, options: PluginPrincipalDropOptions())

        manager.discardChanges()

        #expect(manager.changeCount == 0)
        #expect(manager.isGranted("CONNECT", scope: app, for: alice))
        #expect(manager.isGranted("CREATE", scope: app, for: alice) == false)
    }
}
