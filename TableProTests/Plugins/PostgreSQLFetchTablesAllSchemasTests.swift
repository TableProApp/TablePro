import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.fetchTables across every schema")
struct PostgreSQLFetchTablesAllSchemasTests {
    private static let attempts = PostgreSQLTableListingLadder.degradableAttempts
        + [PostgreSQLTableListingLadder.leastCapableAttempt]

    private func query(
        _ listing: PostgreSQLTableListingScope,
        _ attempt: PostgreSQLTableListingAttempt = PostgreSQLTableListingLadder.degradableAttempts[0]
    ) -> String {
        PostgreSQLSchemaQueries.fetchTables(
            in: listing,
            includeMaterializedViews: attempt.includeOptionalCatalogs,
            includeForeignTables: attempt.includeOptionalCatalogs,
            includeComments: attempt.includeComments,
            includePartitionAwareness: attempt.includePartitionAwareness
        )
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// Every union arm filters by the schema list itself, so a table is listed exactly when its
    /// schema is one `fetchSchemas()` returns, on every rung of the ladder.
    @Test("Every arm is filtered by the schema list query, on every rung")
    func everyArmUsesTheSchemaList() {
        for attempt in Self.attempts {
            let sql = query(.allSchemas, attempt)
            let arms = occurrences(of: "UNION ALL", in: sql) + 1
            #expect(occurrences(of: PostgreSQLSchemaQueries.listSchemas, in: sql) == arms, "\(attempt.label)")
            #expect(occurrences(of: "AS schema_name", in: sql) == arms, "\(attempt.label)")
            #expect(sql.hasSuffix("ORDER BY schema_name, table_name"), "\(attempt.label)")
        }
    }

    @Test("The one-schema listing is the listing it always was")
    func oneSchemaListingUnchanged() {
        for attempt in Self.attempts {
            let sql = query(.schema("public"), attempt)
            #expect(!sql.contains("schema_name"), "\(attempt.label)")
            #expect(!sql.contains(PostgreSQLSchemaQueries.listSchemas), "\(attempt.label)")
            #expect(sql.hasSuffix("ORDER BY table_name"), "\(attempt.label)")
            #expect(sql.contains("t.table_schema = 'public'"), "\(attempt.label)")
        }
    }

    @Test("The all-schema listing keeps the partition exclusion and the comment column")
    func allSchemaListingKeepsItsColumns() {
        let sql = query(.allSchemas)
        #expect(sql.contains("pg_catalog.pg_inherits"))
        #expect(sql.contains("obj_description(pc.oid, 'pg_class')"))
        #expect(sql.contains("pg_matviews"))
        #expect(sql.contains("pg_foreign_table"))
    }

    @Test("A schema name is quoted as a literal in the one-schema listing")
    func schemaLiteralIsQuoted() {
        #expect(query(.schema("it's")).contains("t.table_schema = 'it''s'"))
    }
}
