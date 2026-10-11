//
//  UsersRolesViewModelChangeForwardingTests.swift
//  TableProTests
//
//  The Users & Roles views observe the view model and read staged changes through it, so a change
//  the change manager publishes has to reach them as a change of the view model.
//

import Combine
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Lists one schema under any database, so a lazy expand has something to load.
private final class ScopeTreeDriverStub: PluginDatabaseDriver, PluginPrincipalManagement, @unchecked Sendable {
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
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] { [] }
    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog { PluginPrivilegeCatalog() }
    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] { [] }

    func fetchGrantableChildren(of scope: PluginPrivilegeScope) async throws -> [PluginPrivilegeScope] {
        guard case let .database(database) = scope else { return [] }
        return [.schema(database: database, schema: "public")]
    }

    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? { nil }
    func generateAlterPrincipalSQL(old: PluginPrincipalDefinition, new: PluginPrincipalDefinition) -> [String]? { nil }
    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? { nil }
    func generateDropPrincipalSQL(principal: PluginPrincipalRef, options: PluginPrincipalDropOptions) -> [String]? { nil }
    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }
    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }
}

@MainActor
struct UsersRolesViewModelChangeForwardingTests {
    private final class Counter {
        var value = 0
    }

    private let alice = PluginPrincipalRef(name: "alice")
    private let app = PluginPrivilegeScope.database("app")

    private func makeViewModel() -> UsersRolesViewModel {
        let viewModel = UsersRolesViewModel(connectionId: UUID(), databaseType: .postgresql)
        viewModel.changeManager.load(
            principals: [PluginPrincipalInfo(ref: alice)],
            catalog: PluginPrivilegeCatalog(
                databasePrivileges: [
                    PluginPrivilegeDescriptor(name: "CONNECT", label: "Connect"),
                    PluginPrivilegeDescriptor(name: "CREATE", label: "Create")
                ]
            )
        )
        viewModel.changeManager.loadGrants(
            [PluginGrantInfo(privilege: "CONNECT", scope: app, isGrantable: false)],
            for: alice
        )
        viewModel.selection = alice
        viewModel.selectedRefs = [alice]
        viewModel.selectedScopes = [app]
        return viewModel
    }

    @Test("Ticking a privilege is a change of the view model the checklist observes")
    func tickingAPrivilegeNotifiesTheViewModel() {
        let viewModel = makeViewModel()
        let notifications = Counter()
        let subscription = viewModel.objectWillChange.sink { notifications.value += 1 }
        defer { subscription.cancel() }

        viewModel.setGranted(true, privilege: "CREATE")

        #expect(notifications.value > 0, "the tick was staged but nothing observing the view model heard it")
        #expect(viewModel.grantState(for: "CREATE") == .checked)
        #expect(viewModel.hasChanges)
    }

    @Test("Undoing a staged grant notifies the view model too")
    func undoNotifiesTheViewModel() {
        let viewModel = makeViewModel()
        viewModel.setGranted(true, privilege: "CREATE")
        let notifications = Counter()
        let subscription = viewModel.objectWillChange.sink { notifications.value += 1 }
        defer { subscription.cancel() }

        viewModel.undo()

        #expect(notifications.value > 0)
        #expect(viewModel.grantState(for: "CREATE") == .unchecked)
        #expect(!viewModel.hasChanges)
    }

    // MARK: - Scope tree

    private func configureTree(of viewModel: UsersRolesViewModel) {
        viewModel.privilegeTree.configure(
            databases: ["app"],
            catalog: PluginPrivilegeCatalog(),
            restrictsBrowsing: false,
            currentDatabase: nil,
            loader: PrincipalListLoader(driver: ScopeTreeDriverStub())
        )
    }

    @Test("Switching to Granted is a change of the view model the outline observes")
    func grantedSwitchNotifiesTheViewModel() {
        let viewModel = makeViewModel()
        configureTree(of: viewModel)
        viewModel.scopeMode = .granted
        let notifications = Counter()
        let subscription = viewModel.objectWillChange.sink { notifications.value += 1 }
        defer { subscription.cancel() }

        viewModel.applyScopeMode()

        #expect(notifications.value > 0, "the tree switched to Granted but nothing observing the view model heard it")
        #expect(viewModel.privilegeTree.mode == .granted)
        #expect(viewModel.privilegeTree.node(matching: app)?.hasLoadedChildren == true)
    }

    @Test("A scope search result is a change of the view model the outline observes")
    func searchResultsNotifyTheViewModel() {
        let viewModel = makeViewModel()
        configureTree(of: viewModel)
        let notifications = Counter()
        let subscription = viewModel.objectWillChange.sink { notifications.value += 1 }
        defer { subscription.cancel() }

        viewModel.privilegeTree.showSearchResults([.table(database: "app", schema: "public", table: "orders")])

        #expect(notifications.value > 0, "the search results replaced the roots but nothing observing the view model heard it")
        #expect(viewModel.privilegeTree.mode == .searchResults)
    }

    /// A structure change makes the outline call `reloadData()`, which collapses every row. A lazy
    /// expand fills in one node, so it reports that node and leaves the structure alone.
    @Test("A lazy expand reports its node without a structure change")
    func lazyExpandLeavesTheStructureAlone() async throws {
        let viewModel = makeViewModel()
        configureTree(of: viewModel)
        let tree = viewModel.privilegeTree
        let node = try #require(tree.node(matching: app))
        let version = tree.structureVersion
        let notifications = Counter()
        let changedNodes = Counter()
        let subscription = viewModel.objectWillChange.sink { notifications.value += 1 }
        let nodeSubscription = tree.nodeDidChange.sink { changed in
            if changed === node { changedNodes.value += 1 }
        }
        defer {
            subscription.cancel()
            nodeSubscription.cancel()
        }

        await viewModel.expand(node)

        #expect(tree.structureVersion == version)
        #expect(notifications.value == 0, "a lazy expand would reload the whole outline")
        #expect(changedNodes.value == 2, "the row has to show its spinner and then its children")
        #expect(node.children?.map(\.scope) == [.schema(database: "app", schema: "public")])
        #expect(!node.isLoading)
    }

    @Test("A search result is a leaf, with no disclosure triangle opening onto nothing")
    func searchResultIsALeaf() async throws {
        let viewModel = makeViewModel()
        configureTree(of: viewModel)
        let orders = PluginPrivilegeScope.table(database: "app", schema: "public", table: "orders")
        viewModel.privilegeTree.showSearchResults([orders])
        let node = try #require(viewModel.privilegeTree.node(matching: orders))

        await viewModel.expand(node)

        #expect(!node.isExpandable)
        #expect(node.children?.isEmpty == true)
        #expect(!node.isLoading)
    }
}
