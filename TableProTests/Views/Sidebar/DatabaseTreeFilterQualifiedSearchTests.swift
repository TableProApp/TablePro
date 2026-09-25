//
//  DatabaseTreeFilterQualifiedSearchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DatabaseTreeFilterQualifiedSearchTests {
    private func table(_ name: String, schema: String?) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: 0, schema: schema)
    }

    private func listing(_ tables: [TableInfo], unlisted: Set<String> = []) -> MetadataLoadState<CatalogTableListing.Result> {
        .loaded(CatalogTableListing.Result(tables: tables, unlistedSchemas: unlisted))
    }

    private func buckets(_ tables: [TableInfo], searchText: String) -> DatabaseTreeObjectBuckets {
        DatabaseTreeFilter.objectBuckets(tables: tables, routines: [], triggers: [], searchText: searchText, database: "shop")
    }

    // MARK: - Object filters

    @Test("A qualified search keeps only objects in the schema it names")
    func qualifiedTablesFilter() {
        let tables = [table("timesheet", schema: "attendance"), table("timesheet", schema: "public")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "attendance.time", database: "shop")
        #expect(result.map(\.schema) == ["attendance"])
    }

    @Test("A trailing dot keeps every object in the schema")
    func trailingDotKeepsEverything() {
        let tables = [table("timesheet", schema: "attendance"), table("shift", schema: "attendance")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "attendance.", database: "shop")
        #expect(result.map(\.name) == ["timesheet", "shift"])
    }

    @Test("A table named with a dot is found by typing its name")
    func dottedTableNameStillMatches() {
        let tables = [table("audit.events", schema: "public"), table("orders", schema: "public")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "audit.events", database: "shop")
        #expect(result.map(\.name) == ["audit.events"])
    }

    @Test("A schema holding a table named with a dot is kept for that name")
    func dottedTableNameKeepsItsSchema() {
        let matches = DatabaseTreeFilter.SchemaListingMatches(
            listing: CatalogTableListing.Result(tables: [table("audit.events", schema: "public")], unlistedSchemas: []),
            database: "shop",
            searchText: "audit.events"
        )
        #expect(matches.matched == ["public"])
    }

    @Test("A plain search is unchanged by the database it is told about")
    func plainSearchUnchanged() {
        let tables = [table("timesheet", schema: "attendance"), table("orders", schema: "public")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "sheet", database: "shop")
        #expect(result.map(\.name) == ["timesheet"])
    }

    // MARK: - Schema verdicts

    /// Nil `tables` stands for a listing that has not arrived, which is all a verdict can be told.
    private func verdict(
        _ schema: String,
        search searchText: String,
        tables: [TableInfo]?,
        unlisted: Set<String> = [],
        loadedContent: DatabaseTreeObjectBuckets? = nil,
        listingCoversSchema: Bool = true
    ) -> DatabaseTreeFilter.SchemaSearchVerdict {
        let matches = tables.map {
            DatabaseTreeFilter.SchemaListingMatches(
                listing: CatalogTableListing.Result(tables: $0, unlistedSchemas: unlisted),
                database: "shop",
                searchText: searchText
            )
        }
        return DatabaseTreeFilter.schemaSearchVerdict(
            schema: schema,
            database: "shop",
            searchText: searchText,
            loadedContent: loadedContent,
            listingMatches: matches,
            listingCoversSchema: listingCoversSchema
        )
    }

    @Test("An unloaded schema is judged from the all-schema listing")
    func unloadedSchemaJudgedByListing() {
        let tables = [table("timesheet", schema: "attendance"), table("orders", schema: "sales")]

        #expect(verdict("attendance", search: "timesheet", tables: tables) == .match)
        #expect(verdict("sales", search: "timesheet", tables: tables) == .noMatch)
    }

    @Test("An unloaded schema is unknown while the listing has not arrived")
    func unloadedSchemaUnknownWithoutListing() {
        let result = verdict("attendance", search: "timesheet", tables: nil)

        #expect(result == .unknown)
        #expect(result.isVisible)
    }

    @Test("A schema the listing could not read is unknown, not empty")
    func unlistedSchemaIsUnknown() {
        #expect(verdict("attendance", search: "timesheet", tables: [], unlisted: ["attendance"]) == .unknown)
    }

    @Test("A schema's own loaded lists answer before the listing")
    func loadedContentWins() {
        let loadedWithoutMatch = buckets([table("shift", schema: "attendance")], searchText: "timesheet")

        let result = verdict(
            "attendance", search: "timesheet",
            tables: [table("timesheet", schema: "attendance")], loadedContent: loadedWithoutMatch
        )

        #expect(result == .noMatch)
    }

    @Test("A system schema the listing leaves out is not kept unknown")
    func uncoveredSchemaIsNotUnknown() {
        #expect(verdict("pg_catalog", search: "timesheet", tables: nil, listingCoversSchema: false) == .noMatch)
    }

    @Test("A qualified search drops every schema it does not name")
    func qualifiedSearchDropsOtherSchemas() {
        let tables = [table("timesheet", schema: "attendance"), table("timesheet", schema: "public")]

        #expect(verdict("public", search: "attendance.timesheet", tables: tables) == .noMatch)
        #expect(verdict("attendance", search: "attendance.timesheet", tables: tables) == .match)
    }

    @Test("A plain search matching a schema's own name keeps it")
    func plainSchemaNameMatches() {
        #expect(verdict("attendance", search: "attend", tables: nil) == .match)
    }

    @Test("One pass records every schema listed and every schema holding a match")
    func listingMatchesOnePass() {
        let matches = DatabaseTreeFilter.SchemaListingMatches(
            listing: CatalogTableListing.Result(
                tables: [table("timesheet", schema: "attendance"), table("orders", schema: "sales")],
                unlistedSchemas: ["locked"]
            ),
            database: "shop",
            searchText: "sheet"
        )

        #expect(matches.listed == ["attendance", "sales"])
        #expect(matches.matched == ["attendance"])
        #expect(matches.unlisted == ["locked"])
    }

    // MARK: - Flat list

    @Test("The flat list names the other schemas holding a match, sorted, never the browsed one")
    func otherSchemaMatches() {
        let allSchemas = listing([
            table("timesheet", schema: "public"),
            table("timesheet", schema: "payroll"),
            table("timesheet", schema: "attendance"),
            table("orders", schema: "sales")
        ])
        let schemas = DatabaseTreeFilter.otherSchemaMatches(
            database: "shop", browsedSchema: "public", searchText: "timesheet",
            hiddenSchemas: [], allSchemaTables: allSchemas, loadedContent: { _ in nil }
        )
        #expect(schemas == ["attendance", "payroll"])
    }

    @Test("The flat list does not name a schema that matched only by its own name")
    func otherSchemaMatchesIgnoresSchemaNames() {
        let allSchemas = listing([table("orders", schema: "timesheets")])
        let schemas = DatabaseTreeFilter.otherSchemaMatches(
            database: "shop", browsedSchema: "public", searchText: "timesheet",
            hiddenSchemas: [], allSchemaTables: allSchemas, loadedContent: { _ in nil }
        )
        #expect(schemas.isEmpty)
    }

    @Test("A trailing dot names the schema it asks for")
    func otherSchemaMatchesTrailingDot() {
        let allSchemas = listing([table("orders", schema: "attendance"), table("orders", schema: "sales")])
        let schemas = DatabaseTreeFilter.otherSchemaMatches(
            database: "shop", browsedSchema: "public", searchText: "attendance.",
            hiddenSchemas: [], allSchemaTables: allSchemas, loadedContent: { _ in nil }
        )
        #expect(schemas == ["attendance"])
    }

    @Test("The flat list names nothing until the listing arrives, and nothing hidden")
    func otherSchemaMatchesWithoutListing() {
        let pending = DatabaseTreeFilter.otherSchemaMatches(
            database: "shop", browsedSchema: "public", searchText: "timesheet",
            hiddenSchemas: [], allSchemaTables: .loading, loadedContent: { _ in nil }
        )
        let hidden = DatabaseTreeFilter.otherSchemaMatches(
            database: "shop", browsedSchema: "public", searchText: "timesheet",
            hiddenSchemas: ["attendance"],
            allSchemaTables: listing([table("timesheet", schema: "attendance")]),
            loadedContent: { _ in nil }
        )
        #expect(pending.isEmpty)
        #expect(hidden.isEmpty)
    }

    // MARK: - Hierarchical shape

    private func hierarchicalVerdict(
        _ schema: String,
        searchText: String,
        loaded tables: [TableInfo]? = nil,
        database: String? = nil
    ) -> DatabaseTreeFilter.SchemaSearchVerdict {
        let content = tables.map { tables in
            DatabaseTreeFilter.LoadedSchemaContent(
                buckets: DatabaseTreeFilter.objectBuckets(
                    tables: tables, routines: [], triggers: [], searchText: searchText, database: database
                ),
                isSettled: true,
                isCurrent: true
            )
        }
        return DatabaseTreeFilter.hierarchicalSchemaSearchVerdict(
            schema: schema,
            database: database,
            searchText: searchText,
            loadedContent: content,
            listingMatches: nil,
            listingCoversSchema: true
        )
    }

    @Test("A qualified search hides the hierarchical schemas it does not name")
    func hierarchicalQualified() {
        #expect(hierarchicalVerdict("HR", searchText: "SALES.ORDERS") == .noMatch)
        #expect(hierarchicalVerdict("SALES", searchText: "SALES.ORDERS") == .unknown)
    }

    @Test("A hierarchical search can name the browsed database, and only that one")
    func hierarchicalThreeParts() {
        let loaded = [table("EMPLOYEES", schema: "HR")]
        #expect(hierarchicalVerdict("HR", searchText: "SHOP.HR.EMP", loaded: loaded, database: "SHOP") == .match)
        #expect(hierarchicalVerdict("HR", searchText: "BLOG.HR.EMP", loaded: loaded, database: "SHOP") == .noMatch)
    }

    @Test("A trailing dot shows everything in the hierarchical schema it names")
    func hierarchicalTrailingDot() {
        let buckets = DatabaseTreeFilter.hierarchicalObjectBuckets(
            schema: "SALES",
            tables: [table("ORDERS", schema: "SALES"), table("LINES", schema: "SALES")],
            routines: [], triggers: [], userTypes: [], searchText: "SALES."
        )
        #expect(buckets.itemCounts[.table] == 2)
    }

    @Test("visibleSchemas keeps a qualified search's schema and drops the rest")
    func visibleSchemasQualified() {
        let visible = DatabaseTreeFilter.visibleSchemas(
            ["attendance", "public", "sales"],
            systemSchemas: [],
            activeSchema: nil,
            showsSystem: false,
            searchText: "attendance.",
            database: "shop",
            contentMatches: { _ in false }
        )
        #expect(visible == ["attendance"])
    }

    @Test("While searching, a kind section opens only when it holds a match")
    func searchOpensOnlyMatchingSections() {
        #expect(DatabaseTreeFilter.objectGroupIsExpanded(searching: true, matchCount: 1, stored: false))
        #expect(!DatabaseTreeFilter.objectGroupIsExpanded(searching: true, matchCount: 0, stored: true))
    }

    @Test("Outside a search a kind section keeps the user's choice")
    func noSearchKeepsStoredExpansion() {
        #expect(DatabaseTreeFilter.objectGroupIsExpanded(searching: false, matchCount: 0, stored: true))
        #expect(!DatabaseTreeFilter.objectGroupIsExpanded(searching: false, matchCount: 3, stored: false))
    }
}
