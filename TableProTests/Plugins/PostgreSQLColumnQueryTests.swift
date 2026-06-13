//
//  PostgreSQLColumnQueryTests.swift
//  TableProTests
//
//  Tests for the PostgreSQL and Redshift column introspection query builders
//  (compiled via symlink from PostgreSQLDriverPlugin). Regression cover for
//  autocomplete that ignored the requested schema and always queried the
//  active schema, so columns of a schema-qualified table like `s2.orders`
//  never resolved.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLSchemaQueries.columnsQuery")
struct PostgreSQLColumnsQueryTests {
    private func singleTable(schema: String, table: String) -> String {
        PostgreSQLSchemaQueries.columnsQuery(
            schemaLiteral: schema,
            tableLiteral: table,
            identityProjection: "a.attidentity",
            generatedProjection: "a.attgenerated",
            attributeJoin: "LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = st.relid"
        )
    }

    private func allTables(schema: String) -> String {
        PostgreSQLSchemaQueries.columnsQuery(
            schemaLiteral: schema,
            tableLiteral: nil,
            identityProjection: "NULL::text",
            generatedProjection: "NULL::text",
            attributeJoin: ""
        )
    }

    @Test("single-table query filters on the requested schema and table")
    func singleTableFiltersOnRequestedSchema() {
        let query = singleTable(schema: "s2", table: "orders")
        #expect(query.contains("WHERE c.table_schema = 's2' AND c.table_name = 'orders'"))
        #expect(query.contains("AND tc.table_schema = 's2'"))
        #expect(query.contains("AND tc.table_name = 'orders'"))
    }

    @Test("a non-active schema is not ignored", arguments: ["s2", "analytics", "public"])
    func nonActiveSchemaThreadsThrough(schema: String) {
        let query = singleTable(schema: schema, table: "orders")
        #expect(query.contains("c.table_schema = '\(schema)'"))
    }

    @Test("queries for different schemas differ in the schema literal")
    func differentSchemasProduceDifferentQueries() {
        #expect(singleTable(schema: "s1", table: "t") != singleTable(schema: "s2", table: "t"))
    }

    @Test("single-table query omits the table_name column and orders by ordinal")
    func singleTableOmitsTableNameColumn() {
        let query = singleTable(schema: "s2", table: "orders")
        #expect(!query.contains("c.table_name,"))
        #expect(query.contains("ORDER BY c.ordinal_position"))
        #expect(query.contains("pk ON c.column_name = pk.column_name"))
    }

    @Test("all-tables query selects table_name, drops the table filter, and orders by table")
    func allTablesProjectsTableName() {
        let query = allTables(schema: "s2")
        #expect(query.contains("c.table_name,"))
        #expect(query.contains("WHERE c.table_schema = 's2'"))
        #expect(!query.contains("c.table_name = '"))
        #expect(query.contains("ORDER BY c.table_name, c.ordinal_position"))
        #expect(query.contains("pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name"))
    }

    @Test("version-dependent projections are interpolated verbatim")
    func projectionsInterpolated() {
        let query = singleTable(schema: "s2", table: "orders")
        #expect(query.contains("a.attidentity"))
        #expect(query.contains("a.attgenerated"))
        #expect(query.contains("LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = st.relid"))
    }
}

@Suite("RedshiftSchemaQueries.columnsQuery")
struct RedshiftColumnsQueryTests {
    @Test("single-table query filters on the requested schema and table")
    func singleTableFiltersOnRequestedSchema() {
        let query = RedshiftSchemaQueries.columnsQuery(schemaLiteral: "s2", tableLiteral: "orders")
        #expect(query.contains("WHERE c.table_schema = 's2' AND c.table_name = 'orders'"))
        #expect(query.contains("AND tc.table_schema = 's2'"))
        #expect(query.contains("AND tc.table_name = 'orders'"))
        #expect(!query.contains("c.table_name,"))
        #expect(query.contains("ORDER BY c.ordinal_position"))
    }

    @Test("a non-active schema is not ignored", arguments: ["s2", "analytics", "public"])
    func nonActiveSchemaThreadsThrough(schema: String) {
        let query = RedshiftSchemaQueries.columnsQuery(schemaLiteral: schema, tableLiteral: "orders")
        #expect(query.contains("c.table_schema = '\(schema)'"))
    }

    @Test("all-tables query selects table_name, drops the table filter, and orders by table")
    func allTablesProjectsTableName() {
        let query = RedshiftSchemaQueries.columnsQuery(schemaLiteral: "s2", tableLiteral: nil)
        #expect(query.contains("c.table_name,"))
        #expect(query.contains("WHERE c.table_schema = 's2'"))
        #expect(!query.contains("c.table_name = '"))
        #expect(query.contains("ORDER BY c.table_name, c.ordinal_position"))
        #expect(query.contains("pk ON c.table_name = pk.table_name AND c.column_name = pk.column_name"))
    }
}
