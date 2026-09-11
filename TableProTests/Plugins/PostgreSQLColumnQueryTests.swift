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
    private let modern = PostgreSQLCapabilities(serverVersion: 170_000)
    private let legacy = PostgreSQLCapabilities(serverVersion: 90_100)

    private func singleTable(schema: String, table: String) -> String {
        PostgreSQLSchemaQueries.columnsQuery(schemaLiteral: schema, tableLiteral: table, capabilities: modern)
    }

    private func allTables(schema: String) -> String {
        PostgreSQLSchemaQueries.columnsQuery(schemaLiteral: schema, tableLiteral: nil, capabilities: legacy)
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

    @Test("identity and generated flags are read from pg_attribute by attribute number on 10 and later")
    func modernServerReadsAttributes() {
        let query = singleTable(schema: "s2", table: "orders")
        #expect(query.contains("a.attidentity"))
        #expect(query.contains("a.attgenerated"))
        #expect(query.contains("c.generation_expression"))
        #expect(query.contains("ON a.attrelid = rel.oid"))
        #expect(query.contains("AND a.attnum = c.ordinal_position"))
    }

    @Test("a server without identity or generated columns never names pg_attribute")
    func legacyServerSkipsAttributes() {
        let query = allTables(schema: "s2")
        #expect(!query.contains("pg_attribute"))
        #expect(!query.contains("a.attidentity"))
        #expect(!query.contains("a.attgenerated"))
        #expect(!query.contains("c.generation_expression"))
    }

    @Test("column comments are read through the relation's pg_class oid, not a statistics view")
    func commentsKeyOnRelationOid() {
        for query in [singleTable(schema: "s2", table: "orders"), allTables(schema: "s2")] {
            #expect(!query.contains("pg_statio_all_tables"))
            #expect(query.contains("ON rel.relnamespace = relns.oid"))
            #expect(query.contains("pg_catalog.col_description(rel.oid, c.ordinal_position)"))
        }
    }

    @Test("primary key columns are matched to the constraint's own table")
    func primaryKeyJoinIsTableScoped() {
        for query in [singleTable(schema: "s2", table: "orders"), allTables(schema: "s2")] {
            #expect(query.contains("AND tc.table_name = kcu.table_name"))
        }
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

    @Test("primary key columns are matched to the constraint's own table")
    func primaryKeyJoinIsTableScoped() {
        for table in ["orders", nil] {
            let query = RedshiftSchemaQueries.columnsQuery(schemaLiteral: "s2", tableLiteral: table)
            #expect(query.contains("AND tc.table_name = kcu.table_name"))
        }
    }
}
