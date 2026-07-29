//
//  PostgreSQLDefaultSchemaFallbackTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries default schema fallback")
struct PostgreSQLDefaultSchemaFallbackTests {
    @Test("asks the server for the active schema first")
    func currentSchemaQuery() {
        #expect(PostgreSQLSchemaQueries.currentSchema == "SELECT current_schema()")
    }

    @Test("resolves the first existing search path entry, omitting missing schemas")
    func firstSearchPathSchemaQuery() {
        #expect(PostgreSQLSchemaQueries.firstSearchPathSchema == "SELECT current_schemas(false)[1]")
    }

    @Test("falls back to the effective search path before the alphabetical schema list")
    func fallbackOrdering() {
        #expect(
            PostgreSQLSchemaQueries.schemaFallbackQueries
                == [PostgreSQLSchemaQueries.firstSearchPathSchema, PostgreSQLSchemaQueries.listSchemas]
        )
    }

    @Test("Redshift falls back to the USAGE-filtered schema list")
    func redshiftFallbackOrdering() {
        #expect(
            PostgreSQLSchemaQueries.schemaFallbackQueriesRedshift
                == [PostgreSQLSchemaQueries.firstSearchPathSchema, PostgreSQLSchemaQueries.listSchemasRedshift]
        )
    }

    @Test("schema list fallback returns schemas alphabetically so the first row is deterministic")
    func listSchemasIsOrdered() {
        #expect(PostgreSQLSchemaQueries.listSchemas.contains("ORDER BY schema_name"))
    }
}

@Suite("PostgreSQLSchemaQueries.probe")
struct PostgreSQLSchemaProbeTests {
    @Test("reports the schema when the first cell holds text")
    func schemaFromText() {
        #expect(PostgreSQLSchemaQueries.probe(rows: [[.text("foo")]]) == .schema("foo"))
    }

    @Test("reports empty when the search path resolves to SQL NULL")
    func emptyFromNull() {
        #expect(PostgreSQLSchemaQueries.probe(rows: [[.null]]) == .empty)
    }

    @Test("reports empty when the query returns no rows")
    func emptyFromNoRows() {
        #expect(PostgreSQLSchemaQueries.probe(rows: []) == .empty)
    }

    @Test("reports empty for a blank schema name")
    func emptyFromBlankText() {
        #expect(PostgreSQLSchemaQueries.probe(rows: [[.text("")]]) == .empty)
    }

    @Test("reports failure when the query itself failed")
    func failedFromNilRows() {
        #expect(PostgreSQLSchemaQueries.probe(rows: nil) == .failed)
    }
}
