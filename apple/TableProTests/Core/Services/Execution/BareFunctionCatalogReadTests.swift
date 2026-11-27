//
//  BareFunctionCatalogReadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

// Answers the catalog the way Oracle 23ai answered for a schema with function PURGE, table ORDERS(ID, PURGE) and DUAL.
private final class CatalogDriver: PluginDriverStub, @unchecked Sendable {
    private let fails: Bool

    init(fails: Bool) {
        self.fails = fails
    }

    func execute(query: String) async throws -> PluginQueryResult {
        if fails { throw DatabaseError.notConnected }
        let rows: [[PluginCellValue]]
        if query == SQLCallableCatalog.query {
            rows = [[.text("F"), .text("PURGE")]]
        } else if query.contains("'DUAL'") {
            rows = [[.text("0"), .text("3"), .null, .text("DUMMY")]]
        } else {
            rows = [[.text("0"), .text("1"), .null, .text("ID")], [.text("0"), .text("1"), .null, .text("PURGE")]]
        }
        return PluginQueryResult(
            columns: rows.first.map { $0.indices.map { "C\($0)" } } ?? [],
            columnTypeNames: rows.first.map { $0.map { _ in "VARCHAR2" } } ?? [],
            rows: rows,
            rowsAffected: 0,
            executionTime: 0
        )
    }
}

@MainActor
private final class CatalogProvider: ScopedMetadataProviding {
    private let driver: DatabaseDriver
    private let browse: DatabaseScope?
    private(set) var scopes: [DatabaseScope] = []

    init(fails: Bool = false, browse: DatabaseScope?) {
        let connection = DatabaseConnection(name: "Probe", database: "FREEPDB1", type: .oracle)
        driver = PluginDriverAdapter(connection: connection, pluginDriver: CatalogDriver(fails: fails))
        self.browse = browse
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        scopes.append(scope)
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { browse }
}

@MainActor
struct BareFunctionCatalogReadTests {
    private static func reading(_ sql: String) -> SQLBareNameReading {
        SQLBareNameCalls.read(sql, databaseTypeId: "Oracle", readings: DatabaseType.oracle.lexicalReadings)
    }

    private static func request(_ sql: String, connectionId: UUID, runsIn: DatabaseScope? = nil) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: .oracle,
            sql: sql,
            kind: .readQuery,
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: "Execute Query",
            runsIn: runsIn
        )
    }

    @Test("The session's catalog tells a function named bare from a column, in the schema the tab runs in")
    func readsTheCatalogInTheTabScope() async {
        let connectionId = UUID()
        let browse = DatabaseScope(connectionId: connectionId, database: "FREEPDB1", schema: "APP")
        let tab = DatabaseScope(connectionId: connectionId, database: "FREEPDB1", schema: "HR")
        let provider = CatalogProvider(browse: browse)

        let call = await ExecutionGateProvider.callsBareFunction(
            Self.request("SELECT purge FROM dual", connectionId: connectionId, runsIn: tab),
            reading: Self.reading("SELECT purge FROM dual"),
            catalog: SQLCallableCatalogCache(),
            metadata: provider
        )
        let column = await ExecutionGateProvider.callsBareFunction(
            Self.request("SELECT purge FROM orders", connectionId: connectionId),
            reading: Self.reading("SELECT purge FROM orders"),
            catalog: SQLCallableCatalogCache(),
            metadata: provider
        )

        #expect(call)
        #expect(!column)
        #expect(provider.scopes.first == tab)
        #expect(provider.scopes.last == browse)
    }

    @Test("A catalog that cannot be read, or no scope to read it in, counts as a call")
    func unreadableCatalogRefuses() async {
        let connectionId = UUID()
        let browse = DatabaseScope(connectionId: connectionId, database: "FREEPDB1", schema: nil)

        let failed = await ExecutionGateProvider.callsBareFunction(
            Self.request("SELECT id FROM orders", connectionId: connectionId),
            reading: Self.reading("SELECT id FROM orders"),
            catalog: SQLCallableCatalogCache(),
            metadata: CatalogProvider(fails: true, browse: browse)
        )
        let unscoped = await ExecutionGateProvider.callsBareFunction(
            Self.request("SELECT id FROM orders", connectionId: connectionId),
            reading: Self.reading("SELECT id FROM orders"),
            catalog: SQLCallableCatalogCache(),
            metadata: CatalogProvider(browse: nil)
        )

        #expect(failed)
        #expect(unscoped)
    }
}
