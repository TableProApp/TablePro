import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseTreeFilter")
struct DatabaseTreeFilterTests {
    private func table(_ name: String) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: 0)
    }

    private func routine(_ name: String) -> RoutineInfo {
        RoutineInfo(name: name, schema: "public", kind: .function, signature: nil)
    }

    @Test("filteredTables returns every table and deduplicates when search is empty")
    func filteredTablesNoSearch() {
        let tables = [table("users"), table("orders"), table("users")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "")
        #expect(result.map(\.name) == ["users", "orders"])
    }

    @Test("filteredTables keeps only substring matches when searching")
    func filteredTablesSearch() {
        let tables = [table("users"), table("orders"), table("invoices")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "ord")
        #expect(result.map(\.name) == ["orders"])
    }

    @Test("filteredTables ranks prefix matches above interior-substring matches")
    func filteredTablesRanksPrefixFirst() {
        let tables = [table("audit_user"), table("users"), table("user_log")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "user")
        #expect(result.map(\.name) == ["users", "user_log", "audit_user"])
    }

    @Test("filteredRoutines deduplicates and substring matches")
    func filteredRoutinesSearch() {
        let routines = [routine("calc_total"), routine("audit_log"), routine("calc_total")]
        #expect(DatabaseTreeFilter.filteredRoutines(routines, searchText: "").count == 2)
        #expect(DatabaseTreeFilter.filteredRoutines(routines, searchText: "audit").map(\.name) == ["audit_log"])
    }

    @Test("visibleSchemas drops system schemas and deduplicates")
    func visibleSchemasNoSearch() {
        let schemas = ["public", "pg_catalog", "public", "sales"]
        let result = DatabaseTreeFilter.visibleSchemas(
            schemas,
            systemSchemas: ["pg_catalog"],
            searchText: "",
            contentMatches: { _ in false }
        )
        #expect(result == ["public", "sales"])
    }

    @Test("visibleSchemas keeps a schema when its content matches even if the name does not")
    func visibleSchemasContentMatch() {
        let schemas = ["public", "sales"]
        let result = DatabaseTreeFilter.visibleSchemas(
            schemas,
            systemSchemas: [],
            searchText: "invoice",
            contentMatches: { $0 == "sales" }
        )
        #expect(result == ["sales"])
    }

    /// A search fires a per-schema load, and the pane must not blank out while it runs.
    @Test("An unloaded schema stays visible during a search")
    func unloadedSchemaStaysVisible() {
        #expect(
            DatabaseTreeFilter.hierarchicalSchemaIsVisible(
                "analytics", searchText: "invoice", isLoaded: false, tables: []
            )
        )
    }

    @Test("A loaded schema is dropped only when nothing inside it matches")
    func loadedSchemaNeedsAMatch() {
        #expect(
            !DatabaseTreeFilter.hierarchicalSchemaIsVisible(
                "analytics", searchText: "invoice", isLoaded: true, tables: [table("events")]
            )
        )
        #expect(
            DatabaseTreeFilter.hierarchicalSchemaIsVisible(
                "analytics", searchText: "invoice", isLoaded: true, tables: [table("invoices")]
            )
        )
    }

    @Test("A schema whose own name matches stays visible with nothing loaded inside it")
    func nameMatchedSchemaStaysVisible() {
        #expect(
            DatabaseTreeFilter.hierarchicalSchemaIsVisible(
                "analytics", searchText: "analy", isLoaded: true, tables: []
            )
        )
    }

    /// Filtering the tables of a schema the query already matched leaves it reporting no items.
    @Test("A name-matched schema shows every table it holds")
    func nameMatchedSchemaShowsEverything() {
        let tables = [table("events"), table("sessions")]
        #expect(
            DatabaseTreeFilter.hierarchicalTables(tables, schema: "analytics", searchText: "analytics")
                .map(\.name) == ["events", "sessions"]
        )
    }

    @Test("A schema the query did not match still filters its tables")
    func unmatchedSchemaFiltersTables() {
        let tables = [table("events"), table("sessions")]
        #expect(
            DatabaseTreeFilter.hierarchicalTables(tables, schema: "analytics", searchText: "sess")
                .map(\.name) == ["sessions"]
        )
    }

    @Test("An empty search shows every table")
    func emptySearchShowsEverything() {
        let tables = [table("events"), table("sessions")]
        #expect(
            DatabaseTreeFilter.hierarchicalTables(tables, schema: "analytics", searchText: "")
                .map(\.name) == ["events", "sessions"]
        )
    }

    @Test("matches is a case-insensitive substring test, not a subsequence test")
    func matchesSubstring() {
        #expect(DatabaseTreeFilter.matches("ser", "users"))
        #expect(DatabaseTreeFilter.matches("USER", "users"))
        #expect(!DatabaseTreeFilter.matches("usr", "users"))
        #expect(!DatabaseTreeFilter.matches("zzz", "users"))
    }

    /// The container row needs the counts and every folder under it needs one bucket, so both read
    /// one pass. Filtering per folder re-ran the whole dedup once per open folder.
    @Test("objectBuckets splits one filtered pass into per-kind buckets")
    func objectBucketsSplitByKind() {
        let tables = [
            table("orders"),
            table("orders"),
            TableInfo(name: "order_totals", type: .view, rowCount: 0),
            table("users")
        ]
        let routines = [
            RoutineInfo(name: "order_audit", schema: "public", kind: .procedure, signature: nil),
            routine("calc_total")
        ]
        let buckets = DatabaseTreeFilter.objectBuckets(tables: tables, routines: routines, searchText: "ord")

        #expect(buckets.tables[.table]?.map(\.name) == ["orders"])
        #expect(buckets.tables[.view]?.map(\.name) == ["order_totals"])
        #expect(buckets.routines[.procedure]?.map(\.name) == ["order_audit"])
        #expect(buckets.routines[.function] == nil)
        #expect(buckets.itemCounts == [.table: 1, .view: 1, .procedure: 1])
        #expect(!buckets.isEmpty)
        #expect(DatabaseTreeFilter.objectBuckets(tables: tables, routines: routines, searchText: "zzz").isEmpty)
    }
}
