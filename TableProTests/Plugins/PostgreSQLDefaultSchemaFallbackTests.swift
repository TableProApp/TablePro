//
//  PostgreSQLDefaultSchemaFallbackTests.swift
//  TableProTests
//

import Foundation
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

    @Test("schema list fallback returns schemas alphabetically so the first row is deterministic")
    func listSchemasIsOrdered() {
        #expect(PostgreSQLSchemaQueries.listSchemas.contains("ORDER BY schema_name"))
    }
}
