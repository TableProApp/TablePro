//
//  TableTabIdentityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// Closing tabs after a drop compared bare table names, so dropping `analytics.users` also closed
/// the tab on `public.users` and threw away its row buffer with nothing to undo it.
@Suite("Table tab identity")
struct TableTabIdentityTests {
    private func ref(_ name: String, database: String?, schema: String?) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: database,
            schema: schema,
            table: TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
        )
    }

    @Test("Two schemas of one database are two different objects")
    func schemaSeparatesTwoRowsOfOneName() {
        let analytics = TableTabIdentity(
            ref: ref("users", database: "app", schema: "analytics"),
            browsing: "app",
            resolvedSchema: "analytics"
        )
        let publicUsers = TableTabIdentity(
            ref: ref("users", database: "app", schema: "public"),
            browsing: "app",
            resolvedSchema: "public"
        )

        #expect(analytics != publicUsers)
    }

    @Test("Two databases holding one name are two different objects")
    func databaseSeparatesTwoRowsOfOneName() {
        let staging = TableTabIdentity(
            ref: ref("orders", database: "staging", schema: nil),
            browsing: "staging",
            resolvedSchema: nil
        )
        let production = TableTabIdentity(
            ref: ref("orders", database: "production", schema: nil),
            browsing: "production",
            resolvedSchema: nil
        )

        #expect(staging != production)
    }

    /// The tree activates a row's database before it opens anything, so a tab keyed from the browse
    /// cursor and a row that names the same database are the same object.
    @Test("A row naming its database matches a tab keyed from the browse cursor")
    func rowMatchesTheTabItOpened() {
        let fromRow = TableTabIdentity(
            ref: ref("orders", database: "app", schema: "public"),
            browsing: "app",
            resolvedSchema: "public"
        )
        let fromTab = TableTabIdentity(table: "orders", database: "app", schema: "public")

        #expect(fromRow == fromTab)
    }

    /// A tab restored from a payload written before tabs carried a database has an empty one, which
    /// means the browse cursor. Read raw, it matched no dropped row, so the tab stayed open on a
    /// table that had gone.
    @Test("A tab that names no database of its own takes the browsed one")
    func legacyTabTakesTheBrowsedDatabase() {
        let fromRow = TableTabIdentity(
            ref: ref("orders", database: "app", schema: nil),
            browsing: "app",
            resolvedSchema: nil
        )
        let legacyTab = TableTabIdentity(table: "orders", database: "", schema: nil)

        #expect(fromRow != legacyTab)
        #expect(fromRow == TableTabIdentity(table: "orders", database: "app", schema: nil))
    }

    /// The two sides spell an absent schema differently: a tab that never had one stores the empty
    /// string, a row leaves it nil.
    @Test("An empty schema and no schema are the same object")
    func emptySchemaMatchesNoSchema() {
        #expect(
            TableTabIdentity(table: "orders", database: "app", schema: "")
                == TableTabIdentity(table: "orders", database: "app", schema: nil)
        )
    }

    /// An engine with no databases leaves the row's own empty, and the browse cursor is then the
    /// only thing that names one.
    @Test("A row naming no database takes the browsed one")
    func rowWithoutADatabaseTakesTheBrowsedOne() {
        let identity = TableTabIdentity(
            ref: ref("orders", database: nil, schema: nil),
            browsing: "app",
            resolvedSchema: nil
        )

        #expect(identity.database == "app")
    }
}
