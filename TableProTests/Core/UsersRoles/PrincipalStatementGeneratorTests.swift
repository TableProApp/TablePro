//
//  PrincipalStatementGeneratorTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class MockPrincipalDriver: PluginPrincipalManagement, @unchecked Sendable {
    var supportsPrincipalHostScoping = false
    var supportsOwnedObjectReassignment = true
    var supportsRoleMembership = true

    func fetchPrincipals() async throws -> [PluginPrincipalInfo] { [] }
    func fetchPrivilegeCatalog() async throws -> PluginPrivilegeCatalog { PluginPrivilegeCatalog() }
    func fetchGrants(for principal: PluginPrincipalRef) async throws -> [PluginGrantInfo] { [] }

    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? {
        ["CREATE ROLE \(definition.ref.name)"]
    }

    var alterResult: [String]? = ["ALTER ROLE alice"]

    func generateAlterPrincipalSQL(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String]? {
        alterResult
    }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? {
        ["ALTER ROLE \(principal.name) PASSWORD"]
    }

    func generateDropPrincipalSQL(
        principal: PluginPrincipalRef,
        options: PluginPrincipalDropOptions
    ) -> [String]? {
        options.dropOwned
            ? ["DROP OWNED BY \(principal.name)", "DROP ROLE \(principal.name)"]
            : ["DROP ROLE \(principal.name)"]
    }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        ["GRANT TO \(changeSet.principal.name)"]
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        ["REVOKE FROM \(changeSet.principal.name)"]
    }
}

@Suite("Principal statement generation")
struct PrincipalStatementGeneratorTests {
    private let alice = PluginPrincipalRef(name: "alice")

    @Test("Creates run before grants, revokes before grants, drops last")
    func ordersStatements() throws {
        let generator = PrincipalStatementGenerator(driver: MockPrincipalDriver())
        let changes: [PrincipalChange] = [
            .drop(ref: PluginPrincipalRef(name: "bob"), options: PluginPrincipalDropOptions()),
            .modifyGrants(
                PluginPrincipalChangeSet(
                    principal: alice,
                    grantsToAdd: [PluginGrantInfo(privilege: "CONNECT", scope: .database("app"))],
                    grantsToRemove: [PluginGrantInfo(privilege: "CREATE", scope: .database("app"))]
                )
            ),
            .create(PluginPrincipalDefinition(ref: alice))
        ]

        let sql = try generator.generate(changes: changes).map(\.sql)

        #expect(sql == [
            "CREATE ROLE alice",
            "REVOKE FROM alice",
            "GRANT TO alice",
            "DROP ROLE bob"
        ])
    }

    @Test("Drops and revokes are marked destructive")
    func marksDestructive() throws {
        let generator = PrincipalStatementGenerator(driver: MockPrincipalDriver())
        let statements = try generator.generate(changes: [
            .drop(ref: alice, options: PluginPrincipalDropOptions()),
            .create(PluginPrincipalDefinition(ref: PluginPrincipalRef(name: "carol")))
        ])

        let destructive = statements.filter(\.isDestructive).map(\.sql)
        #expect(destructive == ["DROP ROLE alice"])
    }

    @Test("Drop options reach the driver")
    func passesDropOptions() throws {
        let generator = PrincipalStatementGenerator(driver: MockPrincipalDriver())
        let statements = try generator.generate(changes: [
            .drop(ref: alice, options: PluginPrincipalDropOptions(dropOwned: true))
        ])

        #expect(statements.map(\.sql) == ["DROP OWNED BY alice", "DROP ROLE alice"])
    }

    @Test("A driver returning no statements for an alter is not an error")
    func emptyAlterYieldsNoStatements() throws {
        let driver = MockPrincipalDriver()
        driver.alterResult = []

        let statements = try PrincipalStatementGenerator(driver: driver).generate(changes: [
            .alter(
                old: PluginPrincipalDefinition(ref: alice),
                new: PluginPrincipalDefinition(ref: alice, canLogin: false)
            )
        ])
        #expect(statements.isEmpty)
    }

    @Test("A driver that cannot alter at all still throws")
    func unsupportedAlterThrows() {
        let driver = MockPrincipalDriver()
        driver.alterResult = nil

        #expect(throws: DatabaseError.self) {
            try PrincipalStatementGenerator(driver: driver).generate(changes: [
                .alter(
                    old: PluginPrincipalDefinition(ref: alice),
                    new: PluginPrincipalDefinition(ref: alice, canLogin: false)
                )
            ])
        }
    }
}
