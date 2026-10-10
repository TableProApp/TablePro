import Foundation
import Testing

struct PostgreSQLApproximateRowCountQueryTests {
    @Test("The estimate is read from the named schema and table")
    func namesSchemaAndTableAsLiterals() {
        let query = PostgreSQLSchemaQueries.approximateRowCount(schema: "example", table: "accounts")
        #expect(query.contains("n.nspname = 'example'"))
        #expect(query.contains("c.relname = 'accounts'"))
        #expect(query.contains("JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace"))
    }

    @Test("The estimate never falls back to the session's current schema")
    func ignoresSessionSearchPath() {
        let query = PostgreSQLSchemaQueries.approximateRowCount(schema: "example", table: "accounts")
        #expect(!query.contains("current_schema"))
        #expect(!query.contains("search_path"))
    }

    @Test("The same table name in two schemas gives two different filters")
    func schemasAreDistinguished() {
        let publicQuery = PostgreSQLSchemaQueries.approximateRowCount(schema: "public", table: "accounts")
        let exampleQuery = PostgreSQLSchemaQueries.approximateRowCount(schema: "example", table: "accounts")
        #expect(publicQuery != exampleQuery)
        #expect(publicQuery.contains("n.nspname = 'public'"))
        #expect(!publicQuery.contains("'example'"))
    }

    @Test("A table never analyzed has no estimate, rather than -1 rows")
    func rowEstimateRejectsTheUnanalyzedSentinel() {
        #expect(PostgreSQLSchemaQueries.rowEstimate(reltuples: "-1") == nil)
        #expect(PostgreSQLSchemaQueries.rowEstimate(reltuples: "0") == 0)
        #expect(PostgreSQLSchemaQueries.rowEstimate(reltuples: "1200") == 1_200)
        #expect(PostgreSQLSchemaQueries.rowEstimate(reltuples: nil) == nil)
        #expect(PostgreSQLSchemaQueries.rowEstimate(reltuples: "x") == nil)
    }

    @Test("The estimate is the first and only projected column")
    func projectsReltuplesAlone() {
        let query = PostgreSQLSchemaQueries.approximateRowCount(schema: "public", table: "accounts")
        #expect(query.hasPrefix("SELECT c.reltuples::bigint\nFROM"))
    }
}
