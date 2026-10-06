//
//  UsersRolesViewModelReappearanceTests.swift
//  TableProTests
//
//  The Users & Roles view loads again each time it appears, which is every editor tab switch and
//  every connection switch. A load that reset the change manager there threw away staged creates,
//  passwords and grants, and the undo stack with them.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private actor PrincipalFetchLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct PrincipalFetchRefused: Error {}

/// A server whose principal list the test can change between loads. The loader calls it off the
/// main actor, so its state is locked rather than isolated.
private final class PrincipalServerStub: PluginDatabaseDriver, PluginPrincipalManagement, @unchecked Sendable {
    private struct Hold {
        let reached: PrincipalFetchLatch
        let release: PrincipalFetchLatch
    }

    private let lock = NSLock()
    private var principals: [PluginPrincipalInfo]
    private var refusalsLeft = 0
    private var principalFetches = 0
    private var currentPrincipalHold: Hold?

    init(principals: [PluginPrincipalInfo]) {
        self.principals = principals
    }

    var principalFetchCount: Int {
        lock.withLock { principalFetches }
    }

    func setPrincipals(_ principals: [PluginPrincipalInfo]) {
        lock.withLock { self.principals = principals }
    }

    func refuseNextPrincipalFetch() {
        lock.withLock { refusalsLeft += 1 }
    }

    /// The next `currentPrincipalRef()` opens `reached`, then waits for `release`.
    func holdNextCurrentPrincipal() -> (reached: PrincipalFetchLatch, release: PrincipalFetchLatch) {
        let hold = Hold(reached: PrincipalFetchLatch(), release: PrincipalFetchLatch())
        lock.withLock { currentPrincipalHold = hold }
        return (hold.reached, hold.release)
    }

    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { ["app"] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] {
        let reply: [PluginPrincipalInfo]? = lock.withLock {
            principalFetches += 1
            guard refusalsLeft == 0 else {
                refusalsLeft -= 1
                return nil
            }
            return principals
        }
        guard let reply else { throw PrincipalFetchRefused() }
        return reply
    }

    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog {
        PluginPrivilegeCatalog(
            databasePrivileges: [PluginPrivilegeDescriptor(name: "CONNECT", label: "Connect")]
        )
    }

    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] { [] }

    func currentPrincipalRef() async throws -> PluginPrincipalRef? {
        let hold: Hold? = lock.withLock {
            defer { currentPrincipalHold = nil }
            return currentPrincipalHold
        }
        if let hold {
            await hold.reached.open()
            await hold.release.wait()
        }
        return nil
    }

    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? { nil }
    func generateAlterPrincipalSQL(old: PluginPrincipalDefinition, new: PluginPrincipalDefinition) -> [String]? { nil }
    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? { nil }
    func generateDropPrincipalSQL(principal: PluginPrincipalRef, options: PluginPrincipalDropOptions) -> [String]? { nil }
    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }
    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }
}

@MainActor
struct UsersRolesViewModelReappearanceTests {
    private let alice = PluginPrincipalRef(name: "alice")
    private let bob = PluginPrincipalRef(name: "bob")
    private let carol = PluginPrincipalRef(name: "carol")
    private let app = PluginPrivilegeScope.database("app")

    private func makeViewModel(
        server: PrincipalServerStub
    ) -> (UsersRolesViewModel, DatabaseConnection) {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: server)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: adapter),
            for: connection.id
        )
        let viewModel = UsersRolesViewModel(connectionId: connection.id, databaseType: .postgresql)
        return (viewModel, connection)
    }

    /// Creates bob, changes alice's password and grants alice CONNECT on `app`: three changes,
    /// each its own undo step.
    private func stageWork(on viewModel: UsersRolesViewModel) async {
        viewModel.createPrincipal(PluginPrincipalDefinition(ref: bob, password: "secret"))
        viewModel.setPassword("rotated", for: alice)
        await viewModel.loadGrants(for: alice)
        viewModel.selection = alice
        viewModel.selectedRefs = [alice]
        viewModel.selectedScopes = [app]
        viewModel.setGranted(true, privilege: "CONNECT")
    }

    @Test("Loading again after a load keeps staged changes and Undo")
    func reappearanceKeepsStagedWork() async {
        let server = PrincipalServerStub(principals: [PluginPrincipalInfo(ref: alice)])
        let (viewModel, connection) = makeViewModel(server: server)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await viewModel.load()
        await stageWork(on: viewModel)
        #expect(viewModel.changeCount == 3)

        await viewModel.load()

        #expect(viewModel.changeCount == 3, "a tab or connection switch threw away the staged changes")
        #expect(viewModel.changeManager.pendingCreates.map(\.ref) == [bob])
        #expect(viewModel.changeManager.pendingPasswords[alice] == "rotated")
        #expect(viewModel.grantState(for: "CONNECT") == .checked)
        #expect(viewModel.canUndo, "a tab or connection switch cleared the undo stack")
        #expect(server.principalFetchCount == 1)

        viewModel.undo()

        #expect(viewModel.changeCount == 2)
        #expect(viewModel.grantState(for: "CONNECT") == .unchecked)
    }

    @Test("A forced load fetches again and keeps the work it can rebase")
    func forcedLoadStillReloads() async {
        let server = PrincipalServerStub(principals: [PluginPrincipalInfo(ref: alice)])
        let (viewModel, connection) = makeViewModel(server: server)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await viewModel.load()
        await stageWork(on: viewModel)
        server.setPrincipals([PluginPrincipalInfo(ref: alice), PluginPrincipalInfo(ref: carol)])

        await viewModel.load(forceReload: true)

        #expect(server.principalFetchCount == 2)
        #expect(viewModel.changeManager.principals.map(\.ref) == [alice, carol])
        #expect(viewModel.changeManager.pendingCreates.map(\.ref) == [bob])
        #expect(viewModel.changeManager.pendingPasswords[alice] == "rotated")
        #expect(viewModel.loadError == nil)

        await viewModel.load()

        #expect(server.principalFetchCount == 2, "an appearance after a refresh fetched again")
        #expect(viewModel.changeManager.pendingCreates.map(\.ref) == [bob])
    }

    @Test("A failed first load is retried by the next appearance")
    func failedFirstLoadIsRetried() async {
        let server = PrincipalServerStub(principals: [PluginPrincipalInfo(ref: alice)])
        server.refuseNextPrincipalFetch()
        let (viewModel, connection) = makeViewModel(server: server)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await viewModel.load()
        #expect(viewModel.loadError != nil)
        #expect(viewModel.changeManager.principals.isEmpty)

        await viewModel.load()

        #expect(server.principalFetchCount == 2)
        #expect(viewModel.loadError == nil)
        #expect(viewModel.changeManager.principals.map(\.ref) == [alice])
    }

    /// The view's task is cancelled when it disappears, but the fetch it awaits is not, so a load
    /// from an earlier appearance can finish after the one that put the snapshot in.
    @Test("A load that finishes after another does not reset the work staged in between")
    func lateLoadKeepsStagedWork() async {
        let server = PrincipalServerStub(principals: [PluginPrincipalInfo(ref: alice)])
        let (viewModel, connection) = makeViewModel(server: server)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let hold = server.holdNextCurrentPrincipal()

        let earlier = Task { await viewModel.load() }
        await hold.reached.wait()
        await viewModel.load()
        viewModel.createPrincipal(PluginPrincipalDefinition(ref: bob))
        await hold.release.open()
        await earlier.value

        #expect(viewModel.changeManager.pendingCreates.map(\.ref) == [bob])
        #expect(viewModel.canUndo)
    }
}
