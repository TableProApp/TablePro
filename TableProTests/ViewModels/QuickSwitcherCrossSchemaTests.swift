//
//  QuickSwitcherCrossSchemaTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Quick switcher across schemas")
@MainActor
struct QuickSwitcherCrossSchemaTests {
    private func table(_ name: String, _ schema: String?, type: TableInfo.TableType = .table) -> TableInfo {
        TableInfo(name: name, type: type, rowCount: nil, schema: schema)
    }

    private func items(
        _ tables: [TableInfo],
        browsing browseSchema: String? = "public",
        openTables: Set<QuickSwitcherOpenTable> = []
    ) -> [QuickSwitcherItem] {
        QuickSwitcherViewModel.makeTableItems(
            tables,
            database: "shop",
            connectionSwitchesDatabases: true,
            browseSchema: browseSchema,
            openTables: openTables
        )
    }

    private func search(_ query: String, in catalog: [QuickSwitcherItem]) async -> [QuickSwitcherItem] {
        guard let defaults = UserDefaults(suiteName: "QuickSwitcherCrossSchemaTests.\(UUID().uuidString)") else {
            return []
        }
        let viewModel = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: defaults)
        viewModel.allItems = catalog
        viewModel.searchText = query
        await viewModel.flushPendingFilter()
        return viewModel.flatItems
    }

    // MARK: - Rows

    @Test("A table outside the browsed schema names its schema, and one inside does not")
    func rowsNameOtherSchemas() {
        let rows = items([table("users", "public"), table("timesheet", "attendance")])

        #expect(rows.map(\.subtitle) == ["", "attendance"])
        #expect(rows.map(\.isOutsideBrowsedSchema) == [false, true])
    }

    @Test("A view in another schema names both its schema and its kind")
    func viewNamesSchemaAndKind() {
        let rows = items([table("active", "attendance", type: .view), table("summary", "public", type: .materializedView)])

        #expect(rows.map(\.subtitle) == ["attendance · View", "Materialized View"])
    }

    @Test("A table on an engine without schemas names nothing")
    func schemaLessEngine() {
        let rows = items([table("orders", nil)], browsing: nil)

        #expect(rows.first?.subtitle == "")
        #expect(rows.first?.isOutsideBrowsedSchema == false)
    }

    @Test("A row keeps its table type for the tab it opens")
    func rowsKeepTableType() {
        let rows = items([table("order_seq", "public", type: .sequence), table("summary", "public", type: .materializedView)])

        #expect(rows.map(\.tableType) == [.sequence, .materializedView])
    }

    @Test("A row knows where it lives for a qualified query")
    func rowsCarryLocation() {
        #expect(items([table("timesheet", "attendance")]).first?.searchLocation == ["shop", "attendance"])
    }

    // MARK: - Open state

    @Test("An open table is badged, one without a tab is not")
    func openState() {
        let open: Set<QuickSwitcherOpenTable> = [QuickSwitcherOpenTable(schema: "public", name: "users", browsing: "public")]
        let rows = items([table("users", "public"), table("orders", "public")], openTables: open)

        #expect(rows.first { $0.name == "users" }?.isOpenInTab == true)
        #expect(rows.first { $0.name == "orders" }?.isOpenInTab == false)
    }

    /// The defect #2191 fixed: a tab on `public.users` badged `analytics.users` as open.
    @Test("A table of the same name in another schema is not badged")
    func openStateRespectsSchema() {
        let open: Set<QuickSwitcherOpenTable> = [QuickSwitcherOpenTable(schema: "public", name: "users", browsing: "analytics")]
        let rows = items([table("users", "analytics")], browsing: "analytics", openTables: open)

        #expect(rows.first?.isOpenInTab == false)
    }

    // MARK: - Merging

    @Test("The schema service answers for its own schemas and the listing fills in the rest")
    func mergedTables() {
        let local = [table("users", "public")]
        let allSchemas = [table("users", "public"), table("dropped", "public"), table("timesheet", "attendance")]

        let merged = QuickSwitcherViewModel.mergedTables(
            local: local, loadedFrom: "shop", coveredSchemas: ["public"], listing: allSchemas, browsing: "shop",
            grouping: .bySchema
        )

        #expect(merged.map(\.name) == ["users", "timesheet"])
    }

    /// The last table of `public` was dropped: the schema service reloaded `public` as empty, and
    /// the all-schema listing still holds the table until it is next asked.
    @Test("A schema the schema service found empty keeps the listing's stale rows out")
    func emptyCoveredSchemaKeepsStaleRowsOut() {
        let allSchemas = [table("users", "public"), table("timesheet", "attendance")]

        let merged = QuickSwitcherViewModel.mergedTables(
            local: [], loadedFrom: "shop", coveredSchemas: ["public"], listing: allSchemas, browsing: "shop",
            grouping: .bySchema
        )

        #expect(merged.map(\.name) == ["timesheet"])
    }

    @Test("A table listed twice is merged once")
    func mergedTablesDeduplicate() {
        let allSchemas = [table("timesheet", "attendance"), table("timesheet", "attendance")]

        let merged = QuickSwitcherViewModel.mergedTables(
            local: [], loadedFrom: "shop", coveredSchemas: [], listing: allSchemas, browsing: "shop",
            grouping: .bySchema
        )

        #expect(merged.count == 1)
    }

    /// While a database switch settles, the schema service still holds the old database's tables,
    /// and each would open against the new database.
    @Test("Tables loaded from the database the connection left are not offered")
    func tablesFromThePreviousDatabaseAreWithheld() {
        let merged = QuickSwitcherViewModel.mergedTables(
            local: [table("invoices", "public")],
            loadedFrom: "billing",
            coveredSchemas: ["public"],
            listing: [table("orders", "public"), table("timesheet", "attendance")],
            browsing: "shop",
            grouping: .bySchema
        )

        #expect(merged.map(\.name) == ["orders", "timesheet"])
    }

    /// A hierarchical engine keys its per-schema lists by schema alone, so after a database switch
    /// they can still hold the database the connection left while the listing names the new one.
    @Test("On a hierarchical engine the listing answers for every schema once it has arrived")
    func hierarchicalListingWins() {
        let merged = QuickSwitcherViewModel.mergedTables(
            local: [table("OLD_ORDERS", "PUBLIC")],
            loadedFrom: "SALES",
            coveredSchemas: ["PUBLIC"],
            listing: [table("ORDERS", "PUBLIC")],
            browsing: "SALES",
            grouping: .hierarchicalSchema
        )

        #expect(merged.map(\.name) == ["ORDERS"])
    }

    @Test("On a hierarchical engine the schema service stands in until the listing arrives")
    func hierarchicalBeforeListing() {
        let merged = QuickSwitcherViewModel.mergedTables(
            local: [table("ORDERS", "PUBLIC")],
            loadedFrom: "SALES",
            coveredSchemas: ["PUBLIC"],
            listing: nil,
            browsing: "SALES",
            grouping: .hierarchicalSchema
        )

        #expect(merged.map(\.name) == ["ORDERS"])
    }

    // MARK: - Qualified queries

    @Test("A schema-qualified query finds the table in that schema only")
    func qualifiedQuery() async {
        let catalog = items([table("timesheet", "public"), table("timesheet", "attendance")])

        let results = await search("attendance.timesheet", in: catalog)

        #expect(results.map(\.schemaName) == ["attendance"])
        #expect(results.first?.matchedIndices.isEmpty == false)
    }

    @Test("A trailing dot lists everything in the schema")
    func trailingDot() async {
        let catalog = items([table("timesheet", "attendance"), table("shift", "attendance"), table("users", "public")])

        let results = await search("attendance.", in: catalog)

        #expect(Set(results.map(\.name)) == ["timesheet", "shift"])
    }

    /// A shorter name is a tighter match only when there is a name to match. `attendance.` names
    /// none, so the schema's tables come back the way a list does.
    @Test("A trailing dot lists the schema alphabetically")
    func trailingDotIsAlphabetical() async {
        let catalog = items([
            table("timesheet", "attendance"), table("leave_requests", "attendance"),
            table("shifts", "attendance"), table("holidays", "attendance")
        ])

        let results = await search("attendance.", in: catalog)

        #expect(results.map(\.name) == ["holidays", "leave_requests", "shifts", "timesheet"])
    }

    @Test("A named table still ranks its shorter matches first")
    func namedQueryKeepsShorterFirst() async {
        let catalog = items([table("timesheet_archive", "attendance"), table("timesheet", "attendance")])

        let results = await search("attendance.timesheet", in: catalog)

        #expect(results.map(\.name) == ["timesheet", "timesheet_archive"])
    }

    @Test("Each part of a qualified query matches fuzzily")
    func fuzzyParts() async {
        let catalog = items([table("timesheet", "attendance"), table("orders", "sales")])

        #expect(await search("att.time", in: catalog).map(\.name) == ["timesheet"])
    }

    @Test("A database, schema and name reach the database the connection is browsing")
    func threePartQuery() async {
        let catalog = items([table("timesheet", "attendance")])

        #expect(await search("shop.attendance.timesheet", in: catalog).count == 1)
        #expect(await search("blog.attendance.timesheet", in: catalog).isEmpty)
    }

    @Test("A quoted schema with a dot in it is one schema")
    func quotedSchema() async {
        let catalog = items([table("orders", "my.schema"), table("orders", "my")])

        let results = await search("\"my.schema\".orders", in: catalog)

        #expect(results.map(\.schemaName) == ["my.schema"])
    }

    @Test("A table whose own name holds a dot is still found by that name")
    func dottedTableName() async {
        let catalog = items([table("b.c", "public")])

        #expect(await search("b.c", in: catalog).map(\.name) == ["b.c"])
    }

    @Test("A bare name finds the table in every schema, the browsed schema first")
    func bareNameBrowsedFirst() async {
        let catalog = items([table("timesheet", "attendance"), table("timesheet", "public")])

        let results = await search("timesheet", in: catalog)

        #expect(results.map(\.schemaName) == ["public", "attendance"])
    }

    @Test("A qualified query reaches a result from another connection through its target")
    func qualifiedQueryInConnectionsScope() async throws {
        let target = QuickSwitcherTarget(
            connectionId: UUID(), connectionName: "Primary", databaseName: "app", schemaName: "fallback"
        )
        let remote = QuickSwitcherViewModel.makeCrossConnectionItems(
            tables: [table("timesheet", "attendance"), table("timesheet", "public")],
            target: target,
            connectionSwitchesDatabases: true
        )
        guard let defaults = UserDefaults(suiteName: "QuickSwitcherCrossSchemaTests.\(UUID().uuidString)") else {
            Issue.record("no defaults suite")
            return
        }
        let viewModel = QuickSwitcherViewModel(connectionId: UUID(), services: .live, defaults: defaults)
        viewModel.crossConnectionItems = remote
        viewModel.scope = .connections
        viewModel.searchText = "attendance.timesheet"
        await viewModel.flushPendingFilter()

        #expect(viewModel.flatItems.map { $0.target?.schemaName } == ["attendance"])
    }

    @Test("A path match needs every container it names")
    func pathMatchNeedsEveryContainer() throws {
        let row = try #require(items([table("timesheet", "attendance")]).first)
        let named = try #require(QualifiedSearchQuery("attendance.timesheet"))
        let other = try #require(QualifiedSearchQuery("payroll.timesheet"))

        #expect(QuickSwitcherViewModel.pathMatch(for: row, query: named) != nil)
        #expect(QuickSwitcherViewModel.pathMatch(for: row, query: other) == nil)
    }

    // MARK: - Identity

    private func key(_ name: String, schema: String?, switchesDatabases: Bool) -> String {
        QuickSwitcherFrecencyKey.table(
            name: name,
            schema: schema,
            in: .init(database: "shop", connectionSwitchesDatabases: switchesDatabases)
        )
    }

    @Test("A name without a dot keeps the key it always had on a connection that reaches one database")
    func keyUnchangedWithoutDots() {
        #expect(key("users", schema: "public", switchesDatabases: false) == "table_public.users")
        #expect(key("users", schema: nil, switchesDatabases: false) == "table_users")
    }

    @Test("Dotted names in different schemas never share a key", arguments: [false, true])
    func dottedNamesStayDistinct(switchesDatabases: Bool) {
        let first = key("b.c", schema: "a", switchesDatabases: switchesDatabases)
        let second = key("c", schema: "a.b", switchesDatabases: switchesDatabases)
        let unqualified = key("a.b", schema: nil, switchesDatabases: switchesDatabases)
        let qualified = key("b", schema: "a", switchesDatabases: switchesDatabases)

        #expect(first != second)
        #expect(unqualified != qualified)
    }
}
