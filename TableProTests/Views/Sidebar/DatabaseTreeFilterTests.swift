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
        RoutineInfo(name: name, kind: .function, schema: "public")
    }

    @Test("filteredTables returns every table and deduplicates when search is empty")
    func filteredTablesNoSearch() {
        let tables = [table("users"), table("orders"), table("users")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "")
        #expect(result.map(\.name) == ["users", "orders"])
    }

    @Test("filteredTables keeps two tables whose qualified names differ only in where a period sits")
    func filteredTablesKeepsDottedNamesApart() {
        let tables = [
            TableInfo(name: "b.c", type: .table, rowCount: 0, schema: "a"),
            TableInfo(name: "c", type: .table, rowCount: 0, schema: "a.b"),
            TableInfo(name: "a.b", type: .table, rowCount: 0),
            TableInfo(name: "b", type: .table, rowCount: 0, schema: "a")
        ]
        #expect(DatabaseTreeFilter.filteredTables(tables, searchText: "").count == 4)
        #expect(DatabaseTreeFilter.filteredTables(tables, searchText: "c").count == 2)
    }

    @Test("filteredRoutines and filteredUserTypes keep objects whose schema holds a period")
    func filteredRoutinesAndTypesKeepDottedNamesApart() {
        let routines = [
            RoutineInfo(name: "b.c", kind: .function, schema: "a"),
            RoutineInfo(name: "c", kind: .function, schema: "a.b")
        ]
        let types = [
            UserDefinedTypeInfo(name: "b.c", kind: .enumeration, schema: "a"),
            UserDefinedTypeInfo(name: "c", kind: .enumeration, schema: "a.b")
        ]
        #expect(DatabaseTreeFilter.filteredRoutines(routines, searchText: "").count == 2)
        #expect(DatabaseTreeFilter.filteredUserTypes(types, searchText: "").count == 2)
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

    private func userType(_ name: String) -> UserDefinedTypeInfo {
        UserDefinedTypeInfo(name: name, kind: .enumeration, schema: "public")
    }

    @Test("filteredUserTypes deduplicates and substring matches")
    func filteredUserTypesSearch() {
        let types = [userType("mood"), userType("status"), userType("mood")]
        #expect(DatabaseTreeFilter.filteredUserTypes(types, searchText: "").map(\.name) == ["mood", "status"])
        #expect(DatabaseTreeFilter.filteredUserTypes(types, searchText: "stat").map(\.name) == ["status"])
    }

    @Test("Object buckets count types under the Types kind and keep a type-only container non-empty")
    func objectBucketsCountTypes() {
        let buckets = DatabaseTreeFilter.objectBuckets(
            tables: [],
            routines: [],
            triggers: [],
            userTypes: [userType("mood"), userType("status")],
            searchText: ""
        )
        #expect(!buckets.isEmpty)
        #expect(buckets.itemCounts[.type] == 2)
        #expect(buckets.userTypes.map(\.name) == ["mood", "status"])

        let filtered = DatabaseTreeFilter.objectBuckets(
            tables: [], routines: [], triggers: [], userTypes: [userType("mood")], searchText: "zzz"
        )
        #expect(filtered.isEmpty)
    }

    @Test("A declared Types kind is listed even before any type has loaded")
    func declaredTypesKindIsVisible() {
        let visible = SidebarObjectKind.visible(itemCounts: [:], declaredKinds: [.type], includingEmptyTables: false)
        #expect(visible == [.type])
        #expect(SidebarObjectKind.allCases.last == .type)
    }

    @Test("visibleSchemas drops system schemas and deduplicates")
    func visibleSchemasNoSearch() {
        let schemas = ["public", "pg_catalog", "public", "sales"]
        let result = DatabaseTreeFilter.visibleSchemas(
            schemas,
            systemSchemas: ["pg_catalog"],
            activeSchema: nil,
            showsSystem: false,
            searchText: "",
            contentMatches: { _ in false }
        )
        #expect(result == ["public", "sales"])
    }

    @Test("visibleSchemas lists system schemas when they are shown")
    func visibleSchemasShowsSystemSchemas() {
        let result = DatabaseTreeFilter.visibleSchemas(
            ["public", "pg_catalog"],
            systemSchemas: ["pg_catalog"],
            activeSchema: nil,
            showsSystem: true,
            searchText: "",
            contentMatches: { _ in false }
        )
        #expect(result == ["public", "pg_catalog"])
    }

    @Test("visibleSchemas keeps the browsed system schema listed while system schemas are hidden")
    func visibleSchemasKeepsActiveSystemSchema() {
        let result = DatabaseTreeFilter.visibleSchemas(
            ["APP", "SYSDBA"],
            systemSchemas: ["SYSDBA"],
            activeSchema: "SYSDBA",
            showsSystem: false,
            searchText: "",
            contentMatches: { _ in false }
        )
        #expect(result == ["APP", "SYSDBA"])
    }

    @Test("visibleSchemas keeps a schema when its content matches even if the name does not")
    func visibleSchemasContentMatch() {
        let schemas = ["public", "sales"]
        let result = DatabaseTreeFilter.visibleSchemas(
            schemas,
            systemSchemas: [],
            activeSchema: nil,
            showsSystem: false,
            searchText: "invoice",
            contentMatches: { $0 == "sales" }
        )
        #expect(result == ["sales"])
    }

    private func isVisible(
        _ schema: String,
        searchText: String,
        isLoaded: Bool,
        tables: [TableInfo] = [],
        routines: [RoutineInfo] = [],
        triggers: [TriggerInfo] = []
    ) -> Bool {
        let content = isLoaded
            ? DatabaseTreeFilter.LoadedSchemaContent(
                buckets: DatabaseTreeFilter.objectBuckets(
                    tables: tables,
                    routines: routines,
                    triggers: triggers,
                    searchText: searchText
                ),
                isSettled: true,
                isCurrent: true
            )
            : nil
        return DatabaseTreeFilter.hierarchicalSchemaSearchVerdict(
            schema: schema,
            database: nil,
            searchText: searchText,
            loadedContent: content,
            listingMatches: nil,
            listingCoversSchema: true
        ).isVisible
    }

    private func buckets(
        schema: String,
        tables: [TableInfo],
        routines: [RoutineInfo] = [],
        searchText: String
    ) -> DatabaseTreeObjectBuckets {
        DatabaseTreeFilter.hierarchicalObjectBuckets(
            schema: schema,
            tables: tables,
            routines: routines,
            triggers: [],
            userTypes: [],
            searchText: searchText
        )
    }

    /// Nothing has read it and no listing has answered for it, so hiding it would hide the match.
    @Test("An unloaded schema stays visible during a search")
    func unloadedSchemaStaysVisible() {
        #expect(isVisible("analytics", searchText: "invoice", isLoaded: false))
    }

    @Test("A loaded schema is dropped only when nothing inside it matches")
    func loadedSchemaNeedsAMatch() {
        #expect(!isVisible("analytics", searchText: "invoice", isLoaded: true, tables: [table("events")]))
        #expect(isVisible("analytics", searchText: "invoice", isLoaded: true, tables: [table("invoices")]))
    }

    /// A schema holding only a matching procedure was dropped because the check read tables alone.
    @Test("A procedure, function or trigger that matches keeps its schema")
    func sideObjectMatchKeepsSchema() {
        #expect(isVisible("billing", searchText: "invoice", isLoaded: true, routines: [routine("close_invoice")]))
        let trigger = TriggerInfo(name: "audit", timing: "BEFORE", event: "INSERT", statement: "", table: "invoices")
        #expect(isVisible("billing", searchText: "invoice", isLoaded: true, triggers: [trigger]))
        #expect(!isVisible("billing", searchText: "invoice", isLoaded: true, routines: [routine("refund")]))
    }

    @Test("A schema whose own name matches stays visible with nothing loaded inside it")
    func nameMatchedSchemaStaysVisible() {
        #expect(isVisible("analytics", searchText: "analy", isLoaded: true))
    }

    /// Filtering the objects of a schema the query already matched leaves it reporting no items.
    @Test("A name-matched schema shows every object it holds")
    func nameMatchedSchemaShowsEverything() {
        let result = buckets(
            schema: "analytics",
            tables: [table("events"), table("sessions")],
            routines: [routine("rollup")],
            searchText: "analytics"
        )
        #expect(result.tables[.table]?.map(\.name) == ["events", "sessions"])
        #expect(result.routines[.function]?.map(\.name) == ["rollup"])
    }

    @Test("A schema the query did not match still filters its objects")
    func unmatchedSchemaFiltersObjects() {
        let result = buckets(
            schema: "analytics",
            tables: [table("events"), table("sessions")],
            routines: [routine("session_count"), routine("rollup")],
            searchText: "sess"
        )
        #expect(result.tables[.table]?.map(\.name) == ["sessions"])
        #expect(result.routines[.function]?.map(\.name) == ["session_count"])
    }

    @Test("An empty search shows every object")
    func emptySearchShowsEverything() {
        let result = buckets(schema: "analytics", tables: [table("events"), table("sessions")], searchText: "")
        #expect(result.tables[.table]?.map(\.name) == ["events", "sessions"])
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
            RoutineInfo(name: "order_audit", kind: .procedure, schema: "public"),
            routine("calc_total")
        ]
        let triggers = [
            TriggerInfo(name: "order_guard", timing: "BEFORE", event: "INSERT", statement: "", table: "orders"),
            TriggerInfo(name: "unrelated", timing: "AFTER", event: "DELETE", statement: "", table: "users")
        ]
        let buckets = DatabaseTreeFilter.objectBuckets(
            tables: tables, routines: routines, triggers: triggers, searchText: "ord"
        )

        #expect(buckets.tables[.table]?.map(\.name) == ["orders"])
        #expect(buckets.tables[.view]?.map(\.name) == ["order_totals"])
        #expect(buckets.routines[.procedure]?.map(\.name) == ["order_audit"])
        #expect(buckets.routines[.function] == nil)
        #expect(buckets.triggers.map(\.name) == ["order_guard"])
        #expect(buckets.itemCounts == [.table: 1, .view: 1, .procedure: 1, .trigger: 1])
        #expect(!buckets.isEmpty)
        #expect(
            DatabaseTreeFilter.objectBuckets(
                tables: tables, routines: routines, triggers: triggers, searchText: "zzz"
            ).isEmpty
        )
    }
}
