//
//  DuckDBSchemaQueriesTests.swift
//  TableProTests
//
//  Tests for DuckDBSchemaQueries (compiled via project.yml from DuckDBDriverPlugin).
//  DuckDB's namespace is catalog.schema.table and its catalog views span every attached
//  catalog, so these pin the catalog predicate that keeps one catalog's objects from
//  appearing under another's identically named schema.
//

import Foundation
import Testing

@Suite("DuckDB schema queries")
struct DuckDBSchemaQueriesTests {
    private static let catalogScopedQueries: [(name: String, sql: String)] = [
        ("listSchemas", DuckDBSchemaQueries.listSchemas),
        ("listTables", DuckDBSchemaQueries.listTables),
        ("columnsForTable", DuckDBSchemaQueries.columnsForTable),
        ("columnsForSchema", DuckDBSchemaQueries.columnsForSchema),
        ("primaryKeyColumnsForSchema", DuckDBSchemaQueries.primaryKeyColumnsForSchema),
        ("primaryKeyColumnsForTable", DuckDBSchemaQueries.primaryKeyColumnsForTable),
        ("indexesForTable", DuckDBSchemaQueries.indexesForTable),
        ("foreignKeysForTable", DuckDBSchemaQueries.foreignKeysForTable),
        ("tableDDL", DuckDBSchemaQueries.tableDDL),
        ("viewDefinition", DuckDBSchemaQueries.viewDefinition),
        ("enumTypeNamesForSchema", DuckDBSchemaQueries.enumTypeNamesForSchema),
    ]

    // MARK: - Catalog scoping

    @Test("Every metadata query is anchored to the current catalog")
    func metadataQueriesAreCatalogScoped() {
        for query in Self.catalogScopedQueries {
            #expect(
                query.sql.contains("current_database()"),
                "\(query.name) has no catalog predicate, so it matches same-named schemas in attached catalogs"
            )
        }
    }

    @Test("information_schema queries scope on table_catalog, duckdb_ functions on database_name")
    func catalogPredicateUsesTheRightColumn() {
        for query in Self.catalogScopedQueries {
            let usesInformationSchema = query.sql.contains("information_schema.")
            let expected = usesInformationSchema ? "table_catalog = current_database()" : "database_name = current_database()"
            #expect(query.sql.contains(expected), "\(query.name) should scope with '\(expected)'")
        }
    }

    @Test("The all-tables metadata query is catalog scoped")
    func allTablesMetadataIsCatalogScoped() {
        let sql = DuckDBSchemaQueries.allTablesMetadata(schema: "core")
        #expect(sql.contains("table_catalog = current_database()"))
        #expect(sql.contains("table_schema = 'core'"))
    }

    // MARK: - Schema listing

    @Test("The schema list never filters on the schema's own internal flag")
    func schemaListDoesNotFilterOnInternal() {
        // DuckDB marks the auto-created `main` internal in every catalog, so this
        // predicate would hide the default schema of every database.
        #expect(!DuckDBSchemaQueries.listSchemas.contains("internal"))
    }

    @Test("The schema list reads duckdb_schemas, not the catalog-blind schemata view")
    func schemaListUsesDuckDBSchemas() {
        #expect(DuckDBSchemaQueries.listSchemas.contains("duckdb_schemas()"))
        #expect(!DuckDBSchemaQueries.listSchemas.contains("information_schema.schemata"))
    }

    // MARK: - Database listing

    @Test("The database list hides DuckDB's built-in catalogs")
    func databaseListExcludesInternalCatalogs() {
        #expect(DuckDBSchemaQueries.listDatabases.contains("internal = false"))
        #expect(DuckDBSchemaQueries.listDatabases.contains("duckdb_databases()"))
    }

    // MARK: - Switching

    @Test("Switching schema names the catalog so the two-part form is unambiguous")
    func useSchemaQualifiesWithCatalog() {
        #expect(DuckDBSchemaQueries.useSchema("core", in: "repro") == #"USE "repro"."core""#)
    }

    @Test("Switching schema without a known catalog falls back to the bare form")
    func useSchemaWithoutCatalog() {
        #expect(DuckDBSchemaQueries.useSchema("core", in: nil) == #"USE "core""#)
        #expect(DuckDBSchemaQueries.useSchema("core", in: "") == #"USE "core""#)
    }

    @Test("Switching schema never uses SET schema, which splits its value on a dot")
    func useSchemaDoesNotUseSetSchema() {
        #expect(!DuckDBSchemaQueries.useSchema("a.b", in: "db").contains("SET schema"))
        #expect(DuckDBSchemaQueries.useSchema("a.b", in: "db") == #"USE "db"."a.b""#)
    }

    @Test("Switching database quotes the catalog name")
    func useDatabaseQuotesIdentifier() {
        #expect(DuckDBSchemaQueries.useDatabase("my-db") == #"USE "my-db""#)
    }

    // MARK: - Quoting

    @Test("Embedded double quotes are doubled, not dropped")
    func identifierQuotingEscapesQuotes() {
        #expect(DuckDBSchemaQueries.quoteIdentifier(#"we"ird"#) == #""we""ird""#)
        #expect(DuckDBSchemaQueries.useSchema(#"we"ird"#, in: "repro") == #"USE "repro"."we""ird""#)
    }

    @Test("A quoted identifier cannot be broken out of with an injection payload")
    func identifierQuotingResistsInjection() {
        let payload = #"x"; DROP TABLE users; --"#
        #expect(DuckDBSchemaQueries.useDatabase(payload) == #"USE "x""; DROP TABLE users; --""#)
    }

    @Test("Single quotes in a schema literal are escaped")
    func schemaLiteralEscapesQuotes() {
        let sql = DuckDBSchemaQueries.allTablesMetadata(schema: "it's")
        #expect(sql.contains("table_schema = 'it''s'"))
    }

    @Test("The row count probe qualifies the table with its schema")
    func rowCountProbeQualifiesTable() {
        let sql = DuckDBSchemaQueries.rowCountProbe(schema: "core", table: "bars", limit: 100_001)
        #expect(sql.contains(#""core"."bars""#))
        #expect(sql.contains("LIMIT 100001"))
    }

    @Test("Enum label lookup qualifies the type with its schema")
    func enumLabelsQualifyType() {
        let sql = DuckDBSchemaQueries.enumLabels(schema: "core", typeName: "mood")
        #expect(sql.contains(#"NULL::"core"."mood""#))
    }
}
