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

    @Test("filteredTables keeps only fuzzy matches when searching")
    func filteredTablesSearch() {
        let tables = [table("users"), table("orders"), table("invoices")]
        let result = DatabaseTreeFilter.filteredTables(tables, searchText: "ord")
        #expect(result.map(\.name) == ["orders"])
    }

    @Test("filteredRoutines deduplicates and fuzzy matches")
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

    @Test("matches is a fuzzy subsequence test")
    func matchesFuzzy() {
        #expect(DatabaseTreeFilter.matches("usr", "users"))
        #expect(!DatabaseTreeFilter.matches("zzz", "users"))
    }
}
