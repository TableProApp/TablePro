//
//  ObjectListingRowsTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct ObjectListingRowsTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "sales")

    private func cells(_ rows: TableRows) -> [[String]] {
        rows.rows.map { row in row.values.map { $0.asText ?? "" } }
    }

    private func names(_ rows: TableRows) -> [String] {
        rows.rows.map { $0.values.first?.asText ?? "" }
    }

    private func function(_ name: String) -> RoutineInfo {
        RoutineInfo(name: name, kind: .function, schema: "sales", argumentSignature: "(integer)", returnType: "integer", language: "plpgsql")
    }

    // MARK: - Built kinds

    @Test("Views list name, schema and comment, leave out a Rows column nobody counted, and stand for views")
    func viewsListTheirColumns() {
        let tables = [
            TableInfo(name: "orders", type: .table, rowCount: 10, schema: "sales"),
            TableInfo(name: "recent_orders", type: .view, rowCount: nil, schema: "sales", comment: "Last 30 days"),
        ]

        let listing = ObjectListingRows.listing(kind: .view, from: .relations(tables), scope: scope)

        #expect(listing.rows.columns == [String(localized: "Name"), String(localized: "Schema"), String(localized: "Comment")])
        #expect(cells(listing.rows) == [["recent_orders", "sales", "Last 30 days"]])
        #expect(listing.items[.existing(0)] == .relation(name: "recent_orders", schema: "sales", type: .view))
    }

    @Test("A relation kind whose objects carry row counts lists them as numbers")
    func countedRowsAreNumbers() {
        let tables = [TableInfo(name: "ids", type: .sequence, rowCount: 1, schema: "sales")]

        let listing = ObjectListingRows.listing(kind: .sequence, from: .relations(tables), scope: scope)

        #expect(listing.rows.columns == [String(localized: "Name"), String(localized: "Schema"), String(localized: "Rows")])
        #expect(listing.rows.columnTypes[2] == .integer(rawType: nil))
    }

    @Test("Functions list name, schema, arguments, returns and language, and open as their source")
    func functionsListTheirSignature() {
        let routines = [function("touch"), RoutineInfo(name: "archive", kind: .procedure, schema: "sales")]

        let listing = ObjectListingRows.listing(kind: .function, from: .routines(routines), scope: scope)

        #expect(listing.rows.columns == [
            String(localized: "Name"), String(localized: "Schema"), String(localized: "Arguments"),
            String(localized: "Returns"), String(localized: "Language"),
        ])
        #expect(cells(listing.rows) == [["touch", "sales", "(integer)", "integer", "plpgsql"]])
        #expect(listing.items[.existing(0)] == .sourced(DatabaseObjectRef(routine: routines[0], database: "shop")))
    }

    @Test("Triggers list name, table, timing, event and whether they are enabled")
    func triggersListTheirTable() {
        let trigger = TriggerInfo(name: "audit", timing: "AFTER", event: "INSERT", statement: "", enabled: false, table: "orders", schema: "sales")

        let listing = ObjectListingRows.listing(kind: .trigger, from: .triggers([trigger]), scope: scope)

        #expect(listing.rows.columns == [
            String(localized: "Name"), String(localized: "Table"), String(localized: "Timing"),
            String(localized: "Event"), String(localized: "Enabled"),
        ])
        #expect(cells(listing.rows) == [["audit", "orders", "AFTER", "INSERT", String(localized: "No")]])
        #expect(listing.items[.existing(0)] == .sourced(DatabaseObjectRef(trigger: trigger, database: "shop")))
    }

    @Test("Types list name and schema")
    func typesListNameAndSchema() {
        let mood = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "sales")

        let listing = ObjectListingRows.listing(kind: .type, from: .types([mood]), scope: scope)

        #expect(listing.rows.columns == [String(localized: "Name"), String(localized: "Schema")])
        #expect(cells(listing.rows) == [["mood", "sales"]])
    }

    // MARK: - A plugin listing's columns

    @Test("A plugin listing's name, schema and kind columns are found by their aliases")
    func columnsFoundByAlias() throws {
        let postgres = try #require(ObjectListingColumns(columns: ["schema", "name", "kind", "comment"]))
        let mssql = try #require(ObjectListingColumns(columns: ["schema_name", "name", "kind"]))

        #expect([postgres.name, postgres.schema, postgres.kind] == [1, 0, 2])
        #expect(mssql.schema == 0)
        #expect(ObjectListingColumns(columns: ["Key", "Type"]) == nil)
    }

    @Test("A listing row stands for its relation, in the listed schema where the engine has schemas")
    func itemsReadTheListedSchema() throws {
        let rows = TableRows.from(
            queryRows: [[.text("auth"), .text("users"), .text("VIEW")], [.text(""), .text("orders"), .text("BASE TABLE")]],
            columns: ["schema", "name", "kind"],
            columnTypes: Array(repeating: .text(rawType: nil), count: 3)
        )
        let columns = try #require(ObjectListingColumns(columns: rows.columns))

        let items = columns.items(in: rows, containerSchema: "main", readsSchemaColumn: true)

        #expect(items[.existing(0)] == .relation(name: "users", schema: "auth", type: .view))
        #expect(items[.existing(1)] == .relation(name: "orders", schema: "main", type: .table))
    }

    // MySQL's `schema` alias is TABLE_SCHEMA, the database itself: read as a schema, the table would open as a second tab.
    @Test("Where the namespace is the database, the schema column is not read as a schema")
    func databaseNamespaceIgnoresTheSchemaColumn() throws {
        let rows = TableRows.from(
            queryRows: [[.text("shop"), .text("orders"), .text("BASE TABLE")]],
            columns: ["schema", "name", "kind"],
            columnTypes: Array(repeating: .text(rawType: nil), count: 3)
        )
        let columns = try #require(ObjectListingColumns(columns: rows.columns))

        let items = columns.items(in: rows, containerSchema: nil, readsSchemaColumn: false)

        #expect(items[.existing(0)] == .relation(name: "orders", schema: nil, type: .table))
    }

    static let kindWords: [(String?, TableInfo.TableType)] = [
        ("VIEW", .view), ("view", .view), ("SYSTEM VIEW", .view), ("MATERIALIZED VIEW", .materializedView),
        ("FOREIGN TABLE", .foreignTable), ("SEQUENCE", .sequence), ("BASE TABLE", .table), ("MergeTree", .table), (nil, .table),
    ]

    @Test("A listing's kind word decides how its row opens", arguments: kindWords)
    func kindWordsDecideTheType(word: String?, type: TableInfo.TableType) {
        #expect(ObjectListingColumns.relationType(word) == type)
    }

    // MARK: - Filter

    @Test("The filter keeps rows whose name holds the text, ignoring case, accents and surrounding spaces")
    func filterMatchesNames() {
        let listing = ObjectListingRows.listing(
            kind: .function,
            from: .routines([function("Orders_Total"), function("café_sync"), function("audit")]),
            scope: scope
        )

        #expect(names(ObjectListingFilter.rows(of: listing, matching: "  ORDER ")) == ["Orders_Total"])
        #expect(names(ObjectListingFilter.rows(of: listing, matching: "cafe")) == ["café_sync"])
        #expect(names(ObjectListingFilter.rows(of: listing, matching: "   ")) == ["Orders_Total", "café_sync", "audit"])
    }

    @Test("A filtered row keeps its identity, so a row action reaches the same object")
    func filteredRowsKeepTheirIds() {
        let listing = ObjectListingRows.listing(
            kind: .function, from: .routines([function("touch"), function("audit")]), scope: scope
        )

        let shown = ObjectListingFilter.rows(of: listing, matching: "audit")

        #expect(shown.rows.map(\.id) == [.existing(1)])
        #expect(shown.index(of: .existing(1)) == 0)
    }

    @Test("A listing with no name to match keeps every row")
    func listingWithoutNamesIsNotFiltered() {
        let listing = TableListing(
            rows: TableRows.from(queryRows: [[.text("session:1")]], columns: ["Key"], columnTypes: [.text(rawType: nil)]),
            isIncomplete: false,
            statusMessage: nil
        )

        #expect(listing.items.isEmpty)
        #expect(ObjectListingFilter.rows(of: listing, matching: "zzz").count == 1)
    }
}
