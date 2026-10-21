// SQL Server and Oracle keep users and roles apart: a role never logs in there, and Can log in is a
// user's enable or lock. The toggle is offered only where it means that.

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class PrincipalListStub: PluginDriverStub, PluginPrincipalManagement, @unchecked Sendable {
    private let principals: [PluginPrincipalInfo]

    init(principals: [PluginPrincipalInfo]) {
        self.principals = principals
    }

    var supportsRoleMembership: Bool { true }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchDatabases() async throws -> [String] { ["app"] }
    func fetchPrincipals() async throws -> [PluginPrincipalInfo] { principals }
    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog { PluginPrivilegeCatalog() }
    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] { [] }
    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? { nil }
    func generateAlterPrincipalSQL(old: PluginPrincipalDefinition, new: PluginPrincipalDefinition) -> [String]? { nil }
    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? { nil }
    func generateDropPrincipalSQL(principal: PluginPrincipalRef, options: PluginPrincipalDropOptions) -> [String]? { nil }
    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }
    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { nil }
}

private final class RegistryMSSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Mock SQL Server"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A registry SQL Server plugin"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SQL Server"
    static let databaseDisplayName = "SQL Server"
    static let iconName = "mssql-icon"
    static let defaultPort = 1_433

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@MainActor
struct UsersRolesLoginToggleTests {
    private let alice = PluginPrincipalInfo(ref: PluginPrincipalRef(name: "alice"), canLogin: true)
    private let readers = PluginPrincipalInfo(ref: PluginPrincipalRef(name: "readers"), isRole: true, canLogin: false)

    private func loadedViewModel(type: DatabaseType) async -> (UsersRolesViewModel, DatabaseConnection) {
        let connection = TestFixtures.makeConnection(type: type)
        let adapter = PluginDriverAdapter(
            connection: connection,
            pluginDriver: PrincipalListStub(principals: [alice, readers])
        )
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection, driver: adapter), for: connection.id)
        let viewModel = UsersRolesViewModel(connectionId: connection.id, databaseType: type)
        await viewModel.load()
        return (viewModel, connection)
    }

    @Test("SQL Server and Oracle are curated without role login or a connection limit", arguments: [
        DatabaseType.mssql, .oracle
    ])
    func curatedFlags(type: DatabaseType) {
        #expect(!PluginManager.shared.supportsRoleLogin(for: type))
        #expect(!PluginManager.shared.supportsPrincipalConnectionLimit(for: type))
    }

    @Test("PostgreSQL keeps role login")
    func postgresKeepsRoleLogin() {
        #expect(PluginManager.shared.supportsRoleLogin(for: .postgresql))
    }

    @Test("A registry plugin loading keeps the curated flags")
    func pluginRegistrationKeepsTheFlags() {
        let built = PluginMetadataRegistry.shared.buildMetadataSnapshot(from: RegistryMSSQLPlugin.self)
        #expect(!built.capabilities.supportsRoleLogin)
        #expect(!built.capabilities.supportsPrincipalConnectionLimit)
    }

    @Test("SQL Server offers Can log in on a user only")
    func mssqlOffersTheToggleOnUsers() async {
        let (viewModel, connection) = await loadedViewModel(type: .mssql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(viewModel.allowsLoginToggle(for: alice))
        #expect(!viewModel.allowsLoginToggle(for: readers))
    }

    @Test("A staged create keeps the kind its sheet chose")
    func stagedCreateIsLocked() async throws {
        let (viewModel, connection) = await loadedViewModel(type: .oracle)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        viewModel.createPrincipal(PluginPrincipalDefinition(ref: PluginPrincipalRef(name: "carol"), password: "x"))
        let carol = try #require(viewModel.principalRows.first { $0.ref.name == "carol" })

        #expect(!viewModel.allowsLoginToggle(for: carol.info))
    }

    @Test("PostgreSQL still lets a role log in")
    func postgresOffersTheToggleOnRoles() async {
        let (viewModel, connection) = await loadedViewModel(type: .postgresql)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(viewModel.allowsLoginToggle(for: readers))
    }
}
