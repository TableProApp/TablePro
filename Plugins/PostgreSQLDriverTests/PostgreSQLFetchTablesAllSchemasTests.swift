import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLFetchTablesAllSchemasTests {
    private static let attempts = PostgreSQLTableListingLadder.degradableAttempts
        + [PostgreSQLTableListingLadder.leastCapableAttempt]

    private static let scanFence = "OFFSET 0) c"

    private func query(
        _ listing: PostgreSQLTableListingScope,
        _ attempt: PostgreSQLTableListingAttempt = PostgreSQLTableListingLadder.degradableAttempts[0]
    ) -> String {
        PostgreSQLTableListingLadder.query(
            for: attempt,
            in: listing,
            includeMaterializedViews: true,
            includeForeignTables: true
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("Every rung filters by the schema list query once and projects each row's schema")
    func everyRungUsesTheSchemaList() {
        for attempt in Self.attempts {
            let sql = query(.allSchemas, attempt)
            #expect(occurrences(of: PostgreSQLSchemaQueries.listSchemas, in: sql) == 1, "\(attempt.label)")
            #expect(occurrences(of: "AS schema_name", in: sql) == 1, "\(attempt.label)")
            #expect(sql.hasSuffix("ORDER BY schema_name, table_name"), "\(attempt.label)")
        }
    }

    @Test("The one-schema listing projects no schema and names its schema as a literal")
    func oneSchemaListing() {
        for attempt in Self.attempts {
            let sql = query(.schema("public"), attempt)
            #expect(!sql.contains("schema_name"), "\(attempt.label)")
            #expect(!sql.contains(PostgreSQLSchemaQueries.listSchemas), "\(attempt.label)")
            #expect(sql.hasSuffix("ORDER BY table_name"), "\(attempt.label)")
            #expect(sql.contains("= 'public'"), "\(attempt.label)")
        }
    }

    @Test("A schema set names each schema once and projects each row's schema, on every rung")
    func schemaSetListing() {
        for attempt in Self.attempts {
            let sql = query(.schemas(["a", "it's"]), attempt)
            let column = attempt.source == .systemCatalogs ? "n.nspname" : "t.table_schema"
            #expect(sql.contains("\(column) IN ('a', 'it''s')"), "\(attempt.label)")
            #expect(!sql.contains(PostgreSQLSchemaQueries.listSchemas), "\(attempt.label)")
            #expect(occurrences(of: "AS schema_name", in: sql) == 1, "\(attempt.label)")
            #expect(sql.hasSuffix("ORDER BY schema_name, table_name"), "\(attempt.label)")
        }
    }

    @Test("An empty schema set renders false, since IN () does not parse")
    func emptySchemaSetRendersFalse() {
        #expect(query(.schemas([])).contains("WHERE false\n"))
        #expect(PostgreSQLObjectQueries.membership("n.nspname", in: []) == "false")
    }

    @Test("Only a listing that projects the schema fences its scan")
    func multiSchemaListingsFenceTheScan() {
        for attempt in PostgreSQLTableListingLadder.degradableAttempts {
            #expect(!query(.schema("public"), attempt).contains(Self.scanFence), "\(attempt.label)")
            #expect(query(.schemas(["a"]), attempt).contains(Self.scanFence), "\(attempt.label)")
            #expect(query(.allSchemas, attempt).contains(Self.scanFence), "\(attempt.label)")
        }
    }

    @Test("The all-schema listing keeps the partition exclusion and the comment join")
    func allSchemaListingKeepsItsColumns() {
        let sql = query(.allSchemas)
        #expect(sql.contains("FROM pg_catalog.pg_inherits i"))
        #expect(sql.contains("LEFT JOIN pg_catalog.pg_description d"))
        #expect(sql.contains("rc.relkind IN ('r', 'p', 'v', 'm', 'f')"))
    }

    @Test("A schema name is quoted as a literal in the one-schema listing")
    func schemaLiteralIsQuoted() {
        #expect(query(.schema("it's")).contains("n.nspname = 'it''s'"))
    }
}
