//
//  PrincipalOpenInEditorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class MySQLPrincipalDriverStub: PluginDatabaseDriver, PluginPrincipalManagement, @unchecked Sendable {
    private let accounts = MySQLAccountStatements(
        syntax: .alterUser,
        account: { "'\($0.name)'@'\($0.host ?? "%")'" },
        literal: { mysqlEscapeStringLiteral($0) }
    )

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
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

    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? {
        accounts.create(definition)
    }

    func generateAlterPrincipalSQL(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String]? {
        accounts.alter(old: old, new: new)
    }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? {
        accounts.setPassword(password, for: principal)
    }

    func generateDropPrincipalSQL(
        principal: PluginPrincipalRef,
        options: PluginPrincipalDropOptions
    ) -> [String]? {
        ["DROP USER '\(principal.name)'@'\(principal.host ?? "%")'"]
    }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        changeSet.grantsToAdd.map { "GRANT \($0.privilege) ON *.* TO '\(changeSet.principal.name)'@'%'" }
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        changeSet.grantsToRemove.map { "REVOKE \($0.privilege) ON *.* FROM '\(changeSet.principal.name)'@'%'" }
    }
}

@MainActor
struct PrincipalOpenInEditorTests {
    private let alice = PluginPrincipalRef(name: "alice", host: "%")
    private let bob = PluginPrincipalRef(name: "bob", host: "%")
    private let carol = PluginPrincipalRef(name: "carol", host: "%")
    private let generator = PrincipalStatementGenerator(driver: MySQLPrincipalDriverStub())

    private func makeManager() -> PrincipalChangeManager {
        let manager = PrincipalChangeManager()
        manager.load(
            principals: [PluginPrincipalInfo(ref: bob), PluginPrincipalInfo(ref: carol)],
            catalog: PluginPrivilegeCatalog()
        )
        return manager
    }

    private func withViewModel(_ body: (UsersRolesViewModel) throws -> Void) rethrows {
        let connection = TestFixtures.makeConnection(type: .mysql)
        let session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: MySQLPrincipalDriverStub())
        )
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try body(UsersRolesViewModel(connectionId: connection.id, databaseType: .mysql))
    }

    @Test("A staged create with a password opens in the editor without the password")
    func stagedCreateLeavesPasswordOut() throws {
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: alice, password: "s3cret"))

        let script = try generator.editorScript(changes: manager.pendingChanges())

        #expect(!script.text.contains("s3cret"))
        #expect(script.text == "CREATE USER 'alice'@'%' IDENTIFIED BY '<password>';")
        #expect(script.hidesPasswords)
    }

    @Test("A staged password change opens in the editor without the password")
    func stagedPasswordChangeLeavesPasswordOut() throws {
        let manager = makeManager()
        manager.stageSetPassword("n3w-s3cret", for: bob)

        let script = try generator.editorScript(changes: manager.pendingChanges())

        #expect(!script.text.contains("n3w-s3cret"))
        #expect(script.text == "ALTER USER 'bob'@'%' IDENTIFIED BY '<password>';")
        #expect(script.hidesPasswords)
    }

    @Test("Apply still sends the password the user typed")
    func appliedStatementsKeepPassword() throws {
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: alice, password: "s3cret"))

        let statements = try generator.generate(changes: manager.pendingChanges())

        #expect(statements.map(\.sql) == ["CREATE USER 'alice'@'%' IDENTIFIED BY 's3cret'"])
        #expect(statements.allSatisfy { $0.carriesCredentials })
    }

    @Test("A create without a password opens in the editor as it will run")
    func createWithoutPasswordIsUnchanged() throws {
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: alice, connectionLimit: 5))

        let script = try generator.editorScript(changes: manager.pendingChanges())

        #expect(script.text == "CREATE USER 'alice'@'%' WITH MAX_USER_CONNECTIONS 5;")
        #expect(!script.hidesPasswords)
    }

    @Test("Every staged statement reaches the editor in execution order, one per paragraph")
    func scriptKeepsEveryStatementInOrder() throws {
        let manager = makeManager()
        manager.stageCreate(PluginPrincipalDefinition(ref: alice, password: "s3cret"))
        manager.stageSetPassword("n3w-s3cret", for: bob)
        manager.stageDrop(carol, options: PluginPrincipalDropOptions())

        let script = try generator.editorScript(changes: manager.pendingChanges())

        #expect(script.text == """
        CREATE USER 'alice'@'%' IDENTIFIED BY '<password>';

        ALTER USER 'bob'@'%' IDENTIFIED BY '<password>';

        DROP USER 'carol'@'%';
        """)
    }

    @Test("Review hands Open in Query Editor the create without its password and Execute the create with it")
    func reviewSplitsEditorScriptFromExecutedStatements() {
        withViewModel { viewModel in
            viewModel.changeManager.stageCreate(PluginPrincipalDefinition(ref: alice, password: "s3cret"))

            viewModel.requestApply()

            #expect(viewModel.editorScript.text == "CREATE USER 'alice'@'%' IDENTIFIED BY '<password>';")
            #expect(viewModel.previewSQL == ["CREATE USER 'alice'@'%' IDENTIFIED BY 's3cret'"])
        }
    }

    @Test("Review says the editor script holds a placeholder when a password was replaced")
    func reviewNamesThePlaceholder() {
        withViewModel { viewModel in
            viewModel.changeManager.stageCreate(PluginPrincipalDefinition(ref: alice, password: "s3cret"))

            viewModel.requestApply()

            let notice = viewModel.openInEditorPasswordNotice
            #expect(notice?.contains(PrincipalStatementGenerator.passwordPlaceholder) == true)
        }
    }

    @Test("Review says nothing about a placeholder when no password was staged")
    func reviewIsSilentWithoutPassword() {
        withViewModel { viewModel in
            viewModel.changeManager.stageCreate(PluginPrincipalDefinition(ref: alice, connectionLimit: 5))

            viewModel.requestApply()

            #expect(viewModel.editorScript.text == "CREATE USER 'alice'@'%' WITH MAX_USER_CONNECTIONS 5;")
            #expect(viewModel.openInEditorPasswordNotice == nil)
        }
    }

    @Test("Discarding the staged changes clears the editor script and its notice")
    func discardClearsEditorScript() {
        withViewModel { viewModel in
            viewModel.changeManager.stageCreate(PluginPrincipalDefinition(ref: alice, password: "s3cret"))
            viewModel.requestApply()

            viewModel.discardChanges()

            #expect(viewModel.editorScript == .empty)
            #expect(viewModel.openInEditorPasswordNotice == nil)
        }
    }
}
