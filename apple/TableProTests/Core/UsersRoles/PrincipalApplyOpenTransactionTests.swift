// MySQL and Oracle commit the session's open transaction before a GRANT or CREATE USER runs, so the
// user's pending work would be committed by a Users & Roles apply. The apply is refused instead.

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class TransactionHoldingPrincipalDriver: PluginDriverStub, PluginPrincipalManagement, @unchecked Sendable {
    private let lock = NSLock()
    private var executed: [String] = []
    private let rollsBack: Bool

    init(rollsBack: Bool) {
        self.rollsBack = rollsBack
    }

    var executedQueries: [String] { lock.withLock { executed } }

    var supportsTransactions: Bool { true }
    var rollsBackPrincipalStatements: Bool { rollsBack }

    func sessionTransactionState() async -> PluginSessionTransactionState { .inTransaction }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { executed.append(query) }
        return .empty
    }

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] { [] }
    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog { PluginPrivilegeCatalog() }
    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] { [] }
    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? { ["CREATE USER X"] }
    func generateAlterPrincipalSQL(old: PluginPrincipalDefinition, new: PluginPrincipalDefinition) -> [String]? { [] }
    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? { [] }
    func generateDropPrincipalSQL(principal: PluginPrincipalRef, options: PluginPrincipalDropOptions) -> [String]? { [] }
    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { [] }
    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? { [] }
}

@MainActor
struct PrincipalApplyOpenTransactionTests {
    @Test("An apply that would commit the open transaction runs nothing")
    func refusedWhileTransactionIsOpen() async {
        let driver = TransactionHoldingPrincipalDriver(rollsBack: false)
        let connection = TestFixtures.makeConnection(type: .oracle)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let change = PrincipalChange.create(PluginPrincipalDefinition(ref: PluginPrincipalRef(name: "X"), password: "p"))
        await #expect(throws: DatabaseError.self) {
            try await DatabaseManager.shared.executePrincipalChanges(
                changes: [change],
                databaseType: .oracle,
                connectionId: connection.id
            )
        }
        #expect(driver.executedQueries.isEmpty)
    }
}
