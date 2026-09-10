//
//  SchemaContextForAITests.swift
//  TableProTests
//
//  The schema block that reaches the inline AI suggestion prompt.
//
//  Nothing covered `buildSchemaContextForAI` before, which is how it shipped with a column map
//  keyed one way and read another: every table whose name carried a capital letter listed no
//  columns at all, and the prompt still looked well formed.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("AI schema context")
struct SchemaContextForAITests {
    private static func provider(tables: [TableInfo], columns: [String: [ColumnInfo]]) -> SQLSchemaProvider {
        let source = SQLSchemaProvider.ColumnMetadataSource(
            fetchColumns: { table, _ in columns[table] ?? [] },
            fetchAllColumns: { columns }
        )
        return SQLSchemaProvider(metadataSource: source)
    }

    /// `resetForDatabase` is the path the app actually populates a provider through;
    /// `loadSchema(using:)` has no app caller. A context that only works after the latter is a
    /// context that never works.
    @Test("the populated provider produces a context at all")
    func populatedProviderProducesContext() async {
        let provider = Self.provider(
            tables: [TestFixtures.makeTableInfo(name: "users")],
            columns: ["users": [TestFixtures.makeColumnInfo(name: "id")]]
        )
        await provider.resetForDatabase(
            "shop",
            tables: [TestFixtures.makeTableInfo(name: "users")],
            driver: MockDatabaseDriver(),
            connection: TestFixtures.makeConnection()
        )

        let context = await provider.buildSchemaContextForAI(settings: .default)

        #expect(context != nil)
    }

    /// The producer keyed `table.name.lowercased()` while `AISchemaContext` read `table.name`, so
    /// a capitalised table listed its name and none of its columns. Lower-case names hid it.
    @Test("a table named with capitals still lists its columns")
    func capitalisedTableListsItsColumns() async throws {
        let table = TestFixtures.makeTableInfo(name: "OrderItems")
        let provider = Self.provider(
            tables: [table],
            columns: ["OrderItems": [TestFixtures.makeColumnInfo(name: "quantity", dataType: "INT")]]
        )
        await provider.resetForDatabase(
            "shop",
            tables: [table],
            driver: MockDatabaseDriver(),
            connection: TestFixtures.makeConnection()
        )

        let context = try #require(await provider.buildSchemaContextForAI(settings: .default))

        #expect(context.contains("OrderItems"))
        #expect(context.contains("quantity"))
    }

    @Test("a lower-case table still lists its columns, so the fix did not swap the failure over")
    func lowercaseTableListsItsColumns() async throws {
        let table = TestFixtures.makeTableInfo(name: "orders")
        let provider = Self.provider(
            tables: [table],
            columns: ["orders": [TestFixtures.makeColumnInfo(name: "total", dataType: "DECIMAL")]]
        )
        await provider.resetForDatabase(
            "shop",
            tables: [table],
            driver: MockDatabaseDriver(),
            connection: TestFixtures.makeConnection()
        )

        let context = try #require(await provider.buildSchemaContextForAI(settings: .default))

        #expect(context.contains("orders"))
        #expect(context.contains("total"))
    }

    /// The context names the database the tables came from, which is the tab's scope, not the
    /// sidebar's browse cursor.
    @Test("the context names the scope's database, not the browse cursor")
    func contextNamesTheScopeDatabase() async throws {
        let table = TestFixtures.makeTableInfo(name: "events")
        let provider = Self.provider(tables: [table], columns: ["events": []])
        await provider.resetForDatabase(
            "analytics",
            tables: [table],
            driver: MockDatabaseDriver(),
            connection: TestFixtures.makeConnection(database: "browse_cursor_database")
        )

        let context = try #require(await provider.buildSchemaContextForAI(settings: .default))

        #expect(context.contains("analytics"))
        #expect(!context.contains("browse_cursor_database"))
    }
}
