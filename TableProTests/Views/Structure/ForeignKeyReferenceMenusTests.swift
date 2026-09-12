//
//  ForeignKeyReferenceMenusTests.swift
//  TableProTests
//
//  The Ref Columns menu's read: which container it asks, and what it does with a read that failed.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class ScriptedColumnProvider: ScopedMetadataProviding {
    private let driver = MockDatabaseDriver()
    var browseDatabase: String? = "sidebar_db"
    var failuresRemaining = 0
    private(set) var requestedScopes: [DatabaseScope] = []

    init(
        table: String = "customers",
        columns: [String] = ["id", "display_name"],
        tables: [String] = ["customers", "orders"]
    ) {
        driver.columnsToReturn[table] = columns.map {
            ColumnInfo(name: $0, dataType: "TEXT", isNullable: true, isPrimaryKey: false)
        }
        driver.tablesToReturn = tables.map {
            TableInfo(name: $0, type: .table, rowCount: nil, schema: nil, comment: nil)
        } + [TableInfo(name: "customer_view", type: .view, rowCount: nil, schema: nil, comment: nil)]
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        requestedScopes.append(scope)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw DatabaseError.queryFailed("Table 'sidebar_db.customers' doesn't exist")
        }
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        guard let browseDatabase else { return nil }
        return DatabaseScope(connectionId: connectionId, database: browseDatabase, schema: nil)
    }
}

@Suite("Foreign key reference menus")
@MainActor
struct ForeignKeyReferenceMenusTests {
    private static let connectionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000CD") ?? UUID()

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func menus(
        provider: ScriptedColumnProvider,
        databaseType: DatabaseType = .mysql,
        slot: EngineNamespaceSlot = .database,
        origin: DatabaseScope? = DatabaseScope(
            connectionId: ForeignKeyReferenceMenusTests.connectionId, database: "tab_db", schema: nil
        )
    ) -> ForeignKeyReferenceMenus {
        let menus = ForeignKeyReferenceMenus(
            connectionId: Self.connectionId,
            databaseType: databaseType,
            provider: provider,
            resolveSlot: { _ in slot }
        )
        menus.origin = origin
        return menus
    }

    private func refTableOptions(
        _ menus: ForeignKeyReferenceMenus,
        referencedSchema: String? = nil
    ) -> [GridMenuOption] {
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.referencedSchema = referencedSchema
        return menus.options(columnIndex: 2, foreignKey: foreignKey, tableColumns: []) ?? []
    }

    private func refColumnOptions(
        _ menus: ForeignKeyReferenceMenus,
        table: String = "customers",
        referencedSchema: String? = nil
    ) -> [GridMenuOption] {
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.referencedTable = table
        foreignKey.referencedSchema = referencedSchema
        return menus.options(columnIndex: 3, foreignKey: foreignKey, tableColumns: []) ?? []
    }

    private func titles(_ options: [GridMenuOption]) -> [String] {
        options.compactMap { option in
            switch option {
            case .value(let title, _): return title
            case .sectionHeader(let title): return title
            case .custom(let title): return title
            case .clear(let title): return title
            }
        }
    }

    /// A tab stays on the database it opened while the sidebar moves, so a read routed through the
    /// browse cursor asked about whichever database the sidebar had reached.
    @Test("The read routes through the tab's own scope, not the sidebar's")
    func readsThroughTheTabScope() async {
        let provider = ScriptedColumnProvider()
        let menus = menus(provider: provider)
        _ = refColumnOptions(menus)
        await settle()

        #expect(provider.requestedScopes.first?.database == "tab_db")
        #expect(provider.requestedScopes.allSatisfy { $0.database != "sidebar_db" })
    }

    /// On an engine with no schema layer the row's Ref Schema names a database, so it belongs in the
    /// database slot. Left in the schema slot it is inert and the read stays on the tab's database.
    @Test("A referenced schema on a schema-less engine routes to that database")
    func referencedSchemaBecomesTheDatabase() async {
        let provider = ScriptedColumnProvider()
        let menus = menus(provider: provider)
        _ = refColumnOptions(menus, referencedSchema: "crm")
        await settle()

        #expect(provider.requestedScopes.first?.database == "crm")
        #expect(provider.requestedScopes.first?.schema == nil)
    }

    /// The defect: a failed read cached as an empty list is indistinguishable from a table with no
    /// columns, so the menu offered nothing but Custom for the life of the tab.
    @Test("A failed read is reported and retried, not cached as no columns")
    func failedReadRetriesOnReopen() async {
        let provider = ScriptedColumnProvider()
        provider.failuresRemaining = 1
        let menus = menus(provider: provider)

        _ = refColumnOptions(menus)
        await settle()

        let afterFailure = titles(refColumnOptions(menus))
        #expect(afterFailure.contains { $0.contains("Couldn't read") })
        await settle()

        let afterRetry = titles(refColumnOptions(menus))
        #expect(afterRetry.contains("display_name"))
        #expect(!afterRetry.contains { $0.contains("Couldn't read") })
    }

    /// `SchemaService`'s per-schema lists are filled only for an engine that groups its tree by
    /// schema under a database, so asking it for a named schema on MySQL or PostgreSQL returned an
    /// empty list whatever the connection held, and the Ref Table menu offered nothing.
    @Test("Ref Table lists the referenced container's tables, views excluded")
    func refTableListsTablesFromTheDriver() async {
        let provider = ScriptedColumnProvider()
        let menus = menus(provider: provider)
        _ = refTableOptions(menus, referencedSchema: "crm")
        await settle()

        let names = titles(refTableOptions(menus, referencedSchema: "crm"))
        #expect(names.contains("customers"))
        #expect(names.contains("orders"))
        #expect(!names.contains("customer_view"))
        #expect(provider.requestedScopes.first?.database == "crm")
    }

    /// Both lists are `[String]` in the same container, so a key that does not separate them has the
    /// table list and a table's column list overwrite each other.
    @Test("A container's table list and its columns do not share a cache entry")
    func tableAndColumnListsDoNotCollide() async {
        let provider = ScriptedColumnProvider()
        let menus = menus(provider: provider)
        _ = refTableOptions(menus)
        _ = refColumnOptions(menus)
        await settle()

        let tables = titles(refTableOptions(menus))
        let columns = titles(refColumnOptions(menus))
        #expect(tables.contains("orders"))
        #expect(columns.contains("display_name"))
        #expect(!columns.contains("orders"))
    }

    /// A successful read still answers from the cache rather than asking again on every open.
    @Test("A loaded list is served from the cache")
    func loadedListIsCached() async {
        let provider = ScriptedColumnProvider()
        let menus = menus(provider: provider)
        _ = refColumnOptions(menus)
        await settle()
        let requestsAfterFirstLoad = provider.requestedScopes.count

        _ = refColumnOptions(menus)
        await settle()

        #expect(provider.requestedScopes.count == requestsAfterFirstLoad)
    }

    /// Two tabs on different databases name the same placeholder table, and on a schema-less engine
    /// the raw Ref Schema is nil for both, so a key that ignores the database serves one the other's
    /// columns.
    @Test("Two databases with the same table name do not share a cache entry")
    func cacheKeySeparatesDatabases() async {
        let provider = ScriptedColumnProvider()
        let first = menus(provider: provider)
        _ = refColumnOptions(first)
        await settle()

        let second = menus(
            provider: provider,
            origin: DatabaseScope(connectionId: Self.connectionId, database: "other_db", schema: nil)
        )
        _ = refColumnOptions(second)
        await settle()

        #expect(provider.requestedScopes.map(\.database).contains("tab_db"))
        #expect(provider.requestedScopes.map(\.database).contains("other_db"))
    }
}
