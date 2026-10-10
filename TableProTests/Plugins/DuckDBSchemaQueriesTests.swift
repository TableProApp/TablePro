//
//  DuckDBSchemaQueriesTests.swift
//  TableProTests
//
//  Tests for DuckDBSchemaQueries (compiled via project.yml from DuckDBDriverPlugin).
//  DuckDB's namespace is catalog.schema.table and its catalog views span every attached
//  catalog, so these pin the catalog predicate that keeps one catalog's objects from
//  appearing under another's identically named schema.
//
//  They also pin the queries away from `core_functions`. The macOS libduckdb links no
//  extensions, so `current_database()`, `current_schema()`,
//  `information_schema.key_column_usage` and `information_schema.referential_constraints`
//  only answer once DuckDB has downloaded core_functions from extensions.duckdb.org.
//  scripts/probes/check-duckdb-offline-metadata.sh runs the same queries against the shipped
//  library with no extensions available.
//

import Foundation
import Testing

struct DuckDBSchemaQueriesTests {
    private static let catalogScopedQueries: [(name: String, sql: String)] = [
        ("listSchemas", DuckDBSchemaQueries.listSchemas),
        ("listTables(in: .schema)", DuckDBSchemaQueries.listTables(in: .schema)),
        ("listTables(in: .allSchemas)", DuckDBSchemaQueries.listTables(in: .allSchemas)),
        ("columnsForTable", DuckDBSchemaQueries.columnsForTable),
        ("columnsForSchema", DuckDBSchemaQueries.columnsForSchema),
        ("primaryKeyColumnsForSchema", DuckDBSchemaQueries.primaryKeyColumnsForSchema),
        ("primaryKeyColumnsForTable", DuckDBSchemaQueries.primaryKeyColumnsForTable),
        ("indexesForTable", DuckDBSchemaQueries.indexesForTable),
        ("foreignKeysForTable", DuckDBSchemaQueries.foreignKeysForTable),
        ("tableDDL", DuckDBSchemaQueries.tableDDL),
        ("viewDefinition", DuckDBSchemaQueries.viewDefinition),
        ("objectComment", DuckDBSchemaQueries.objectComment),
    ]

    private static let allQueries: [(name: String, sql: String)] =
        catalogScopedQueries + [
            ("listDatabases", DuckDBSchemaQueries.listDatabases),
            ("currentPosition", DuckDBSchemaQueries.currentPosition),
            (
                "allTablesMetadata",
                DuckDBSchemaQueries.allTablesMetadata(catalog: "repro", escapedSchema: "core")
            ),
        ]

    // MARK: - Extension independence

    @Test("No metadata query calls a function that lives in the core_functions extension")
    func metadataQueriesNeedNoExtension() {
        for query in Self.allQueries {
            #expect(
                !query.sql.contains("current_database()"),
                "\(query.name) calls current_database(), which needs the core_functions download"
            )
            #expect(
                !query.sql.contains("current_schema()"),
                "\(query.name) calls current_schema(), which needs the core_functions download"
            )
        }
    }

    @Test("No metadata query reads an information_schema view built on core_functions")
    func metadataQueriesAvoidExtensionBackedViews() {
        for query in Self.allQueries {
            #expect(
                !query.sql.contains("key_column_usage"),
                "\(query.name) reads key_column_usage, which needs the core_functions download"
            )
            #expect(
                !query.sql.contains("referential_constraints"),
                "\(query.name) reads referential_constraints, which needs the core_functions download"
            )
        }
    }

    // MARK: - Catalog scoping

    @Test("Every metadata query is anchored to the catalog through its first parameter")
    func metadataQueriesAreCatalogScoped() {
        for query in Self.catalogScopedQueries {
            #expect(
                query.sql.contains("database_name = $1"),
                "\(query.name) has no catalog predicate, so it matches same-named schemas in attached catalogs"
            )
        }
    }

    @Test("The all-tables metadata query is catalog scoped")
    func allTablesMetadataIsCatalogScoped() {
        let sql = DuckDBSchemaQueries.allTablesMetadata(catalog: "repro", escapedSchema: "core")
        #expect(sql.contains("database_name = 'repro'"))
        #expect(sql.contains("schema_name = 'core'"))
    }

    // MARK: - Position

    @Test("The current position comes from settings, not from a scalar function")
    func currentPositionReadsSettings() {
        #expect(DuckDBSchemaQueries.currentPosition.contains("duckdb_settings()"))
        #expect(DuckDBSchemaQueries.currentPosition.contains("search_path"))
        #expect(DuckDBSchemaQueries.currentPosition.contains("'schema'"))
    }

    // MARK: - Schema listing

    @Test("The schema list never filters on the schema's own internal flag")
    func schemaListDoesNotFilterOnInternal() {
        #expect(!DuckDBSchemaQueries.listSchemas.contains("internal"))
    }

    @Test("The schema list reads duckdb_schemas, not the catalog-blind schemata view")
    func schemaListUsesDuckDBSchemas() {
        #expect(DuckDBSchemaQueries.listSchemas.contains("duckdb_schemas()"))
        #expect(!DuckDBSchemaQueries.listSchemas.contains("information_schema.schemata"))
    }

    // MARK: - Object listing

    @Test(
        "The table list reports views alongside tables and hides internal objects in both",
        arguments: [DuckDBTableListingScope.schema, .allSchemas]
    )
    func tableListIncludesViews(scope: DuckDBTableListingScope) {
        let sql = DuckDBSchemaQueries.listTables(in: scope)
        #expect(sql.contains("duckdb_tables()"))
        #expect(sql.contains("duckdb_views()"))
        #expect(sql.contains("'BASE TABLE'"))
        #expect(sql.contains("'VIEW'"))
        #expect(
            sql.components(separatedBy: "internal = false").count == 3,
            "both the table branch and the view branch must hide internal objects"
        )
    }

    @Test("The one-schema listing binds the schema and projects no schema column")
    func oneSchemaListingBindsTheSchema() {
        let sql = DuckDBSchemaQueries.listTables(in: .schema)
        #expect(sql.components(separatedBy: "schema_name = $2").count == 3)
        #expect(!sql.contains(DuckDBSchemaQueries.listSchemas))
        #expect(!sql.contains(", schema_name"))
        #expect(sql.hasSuffix("ORDER BY 1"))
    }

    @Test("Every arm of the all-schema listing is filtered by the schema list query itself")
    func allSchemaListingFiltersByTheSchemaList() {
        let sql = DuckDBSchemaQueries.listTables(in: .allSchemas)
        #expect(sql.components(separatedBy: "schema_name IN (\n\(DuckDBSchemaQueries.listSchemas)\n)").count == 3)
        #expect(!sql.contains("$2"))
        #expect(sql.components(separatedBy: ", schema_name\n").count == 3)
        #expect(sql.hasSuffix("ORDER BY 3, 1"))
    }

    // MARK: - Keys

    @Test("Primary key columns are unnested so a composite key yields one row per column")
    func primaryKeyColumnsUnnestTheList() {
        #expect(DuckDBSchemaQueries.primaryKeyColumnsForTable.contains("UNNEST(constraint_column_names)"))
        #expect(DuckDBSchemaQueries.primaryKeyColumnsForSchema.contains("UNNEST(constraint_column_names)"))
        #expect(DuckDBSchemaQueries.primaryKeyColumnsForTable.contains("'PRIMARY KEY'"))
    }

    @Test("Foreign keys unnest both column lists so a composite key pairs by position")
    func foreignKeysUnnestBothLists() {
        let sql = DuckDBSchemaQueries.foreignKeysForTable
        #expect(sql.contains("UNNEST(constraint_column_names)"))
        #expect(sql.contains("UNNEST(referenced_column_names)"))
        #expect(sql.contains("'FOREIGN KEY'"))
    }

    @Test("Foreign key rules are NO ACTION, which is all DuckDB accepts")
    func foreignKeyRulesAreNoAction() {
        let sql = DuckDBSchemaQueries.foreignKeysForTable
        #expect(sql.contains("'NO ACTION' AS delete_rule"))
        #expect(sql.contains("'NO ACTION' AS update_rule"))
    }

    // MARK: - Enums

    /// DuckDB spells an ENUM's members into the column's own type as `ENUM('ok', 'bad')`, so
    /// nothing needs to look them up. The query that used to try keyed its result on
    /// `type_name`, which never matched a column's `data_type`, so it answered nothing.
    @Test("No query looks enum labels up separately")
    func noQueryFetchesEnumLabels() {
        for query in Self.allQueries {
            #expect(!query.sql.contains("enum_range"), "\(query.name) still calls enum_range")
            #expect(!query.sql.contains("duckdb_types()"), "\(query.name) still reads duckdb_types()")
        }
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

    /// The catalog arrives raw and the schema arrives already escaped by
    /// `SchemaSwitchable.escapedSchema`, so only one of the two may be escaped here.
    @Test("The catalog is escaped and the already-escaped schema is passed through")
    func onlyTheCatalogIsEscaped() {
        let sql = DuckDBSchemaQueries.allTablesMetadata(catalog: #"o'db"#, escapedSchema: #"it''s"#)
        #expect(sql.contains(#"database_name = 'o''db'"#))
        #expect(sql.contains(#"schema_name = 'it''s'"#))
        #expect(!sql.contains(#"it''''s"#))
    }

    @Test("A raw catalog cannot be broken out of with an injection payload")
    func catalogQuotingResistsInjection() {
        let sql = DuckDBSchemaQueries.allTablesMetadata(
            catalog: #"x'; DROP TABLE users; --"#, escapedSchema: "main"
        )
        #expect(sql.contains(#"database_name = 'x''; DROP TABLE users; --'"#))
    }

    @Test("The row count probe qualifies the table with its schema")
    func rowCountProbeQualifiesTable() {
        let sql = DuckDBSchemaQueries.rowCountProbe(schema: "core", table: "bars", limit: 100_001)
        #expect(sql.contains(#""core"."bars""#))
        #expect(sql.contains("LIMIT 100001"))
    }

    // MARK: - Comments

    @Test("The object comment is read from tables and views, by catalog, schema and name")
    func objectCommentReadsTablesAndViews() {
        let sql = DuckDBSchemaQueries.objectComment
        #expect(sql.contains("FROM duckdb_tables()"))
        #expect(sql.contains("FROM duckdb_views()"))
        #expect(sql.contains("table_name = $3"))
        #expect(sql.contains("view_name = $3"))
        #expect(sql.components(separatedBy: "schema_name = $2").count == 3)
    }

    @Test("Both column queries select the column comment")
    func columnQueriesSelectTheComment() {
        #expect(DuckDBSchemaQueries.columnsForTable.contains("column_index, comment\n"))
        #expect(DuckDBSchemaQueries.columnsForSchema.contains("column_index, comment\n"))
    }

    @Test("A table and a view each get their own keyword")
    func objectCommentKeywords() {
        #expect(DuckDBSchemaQueries.objectCommentStatement(objectType: "TABLE", schema: "s", name: "t", comment: "c")
            == #"COMMENT ON TABLE "s"."t" IS 'c'"#)
        #expect(DuckDBSchemaQueries.objectCommentStatement(objectType: "VIEW", schema: "s", name: "v", comment: "c")
            == #"COMMENT ON VIEW "s"."v" IS 'c'"#)
    }

    @Test("Other kinds cannot be commented", arguments: ["MATERIALIZED VIEW", "SEQUENCE", "SYSTEM TABLE", ""])
    func otherKindsHaveNoCommentStatement(kind: String) {
        #expect(DuckDBSchemaQueries.objectCommentStatement(objectType: kind, schema: "s", name: "t", comment: nil) == nil)
    }

    /// Measured on 1.5.2: `IS ''` stores an empty string, and only `IS NULL` clears the comment.
    @Test("A nil or empty comment removes it with NULL")
    func emptyCommentClears() {
        #expect(DuckDBSchemaQueries.objectCommentStatement(objectType: "TABLE", schema: "s", name: "t", comment: nil)
            == #"COMMENT ON TABLE "s"."t" IS NULL"#)
        #expect(DuckDBSchemaQueries.objectCommentStatement(objectType: "TABLE", schema: "s", name: "t", comment: "")
            == #"COMMENT ON TABLE "s"."t" IS NULL"#)
    }

    @Test("A comment doubles its quotes and keeps a backslash as written")
    func commentEscaping() {
        let sql = DuckDBSchemaQueries.objectCommentStatement(
            objectType: "TABLE", schema: #"we"ird"#, name: "t", comment: #"it's a \ table"#
        )
        #expect(sql == #"COMMENT ON TABLE "we""ird"."t" IS 'it''s a \ table'"#)
    }

    @Test("A quote followed by a combining mark is still doubled")
    func quoteBeforeCombiningMark() {
        #expect(DuckDBSchemaQueries.quoteLiteral("a'\u{301}b") == "'a''\u{301}b'")
        #expect(DuckDBSchemaQueries.quoteIdentifier("x\"\u{301}") == "\"x\"\"\u{301}\"")
    }

    @Test("A column comment names the schema, the table and the column")
    func columnComment() {
        #expect(DuckDBSchemaQueries.columnCommentStatement(schema: "s", table: "t", column: "c", comment: "x'y")
            == #"COMMENT ON COLUMN "s"."t"."c" IS 'x''y'"#)
    }

    // MARK: - Auto-increment

    /// `DROP TABLE` leaves the sequence behind, so creating the table again must not fail on it.
    @Test("The sequence is created only when it does not exist yet")
    func sequenceIfNotExists() {
        #expect(DuckDBSchemaQueries.createSequenceStatement(schema: "main", sequence: "t_id_seq")
            == #"CREATE SEQUENCE IF NOT EXISTS "main"."t_id_seq""#)
    }

    @Test("The sequence is named after the table and the column, without any double quote")
    func sequenceName() {
        #expect(DuckDBSchemaQueries.autoIncrementSequenceName(table: "orders", column: "id") == "orders_id_984a0109_seq")
        #expect(DuckDBSchemaQueries.autoIncrementSequenceName(table: #"q"x"#, column: "id") == "qx_id_0f74cfff_seq")
    }

    @Test("Two table and column pairs that read the same get different sequences")
    func sequenceNamesDoNotCollide() {
        let underscoreInTable = DuckDBSchemaQueries.autoIncrementSequenceName(table: "a_b", column: "id")
        let underscoreInColumn = DuckDBSchemaQueries.autoIncrementSequenceName(table: "a", column: "b_id")
        #expect(underscoreInTable != underscoreInColumn)
        let quoted = DuckDBSchemaQueries.autoIncrementSequenceName(table: #"q"x"#, column: "id")
        let plain = DuckDBSchemaQueries.autoIncrementSequenceName(table: "qx", column: "id")
        #expect(quoted != plain)
    }

    @Test("nextval takes the qualified sequence as a string literal")
    func nextvalQualifiesTheSequence() {
        #expect(DuckDBSchemaQueries.nextvalDefault(schema: "main", sequence: "t_id_seq")
            == #"nextval('"main"."t_id_seq"')"#)
        #expect(DuckDBSchemaQueries.nextvalDefault(schema: "main", sequence: "t's.x_seq")
            == #"nextval('"main"."t''s.x_seq"')"#)
    }

    /// Measured on 1.5.2: `nextval('"we""ird"."s"')` looks for `s` in no schema at all.
    @Test("A schema holding a double quote is left to resolve as the table's own")
    func nextvalWithQuotedSchema() {
        #expect(DuckDBSchemaQueries.nextvalDefault(schema: #"we"ird"#, sequence: "t_id_seq")
            == #"nextval('"t_id_seq"')"#)
    }
}
