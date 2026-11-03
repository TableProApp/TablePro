import TableProTrinoCore
import Testing

struct TrinoIntrospectionSQLTests {
    @Test("A schema set is listed in one query that names each schema and projects it")
    func schemaSetListing() {
        let statement = TrinoIntrospectionSQL.listTables(catalog: "hive", inSchemas: ["sales", "o'brien"])
        #expect(statement.contains("FROM \"hive\".information_schema.tables"))
        #expect(statement.contains("WHERE table_schema IN ('sales', 'o''brien')"))
        #expect(statement.contains("SELECT table_name, table_type, table_schema"))
        #expect(TrinoIntrospectionSQL.listTables(catalog: "hive", inSchemas: []).contains("WHERE false"))
    }

    @Test("A schema set's materialized views come from one query that projects the schema")
    func schemaSetMaterializedViews() {
        let statement = TrinoIntrospectionSQL.listMaterializedViews(
            catalog: "iceberg", inSchemas: ["a", "b"], flavor: .trino
        )
        #expect(statement.contains("SELECT name, schema_name FROM system.metadata.materialized_views"))
        #expect(statement.contains("catalog_name = 'iceberg' AND schema_name IN ('a', 'b')"))
    }

    @Test("On Presto a schema set's materialized views come from information_schema in one query")
    func prestoSchemaSetMaterializedViews() {
        let statement = TrinoIntrospectionSQL.listMaterializedViews(
            catalog: "hive", inSchemas: ["a", "o'brien"], flavor: .presto
        )
        #expect(statement.contains(#"SELECT table_name, table_schema FROM "hive".information_schema.materialized_views"#))
        #expect(statement.contains("WHERE table_schema IN ('a', 'o''brien')"))
    }

    @Test("A quote that a combining mark follows is still doubled")
    func combiningMarkCannotHideAQuote() {
        #expect(TrinoIntrospectionSQL.quoteLiteral("x'\u{301} OR true--") == "'x''\u{301} OR true--'")
        #expect(TrinoIntrospectionSQL.quoteIdentifier("a\"\u{301}") == "\"a\"\"\u{301}\"")
    }

    @Test("A SHOW STATS row count reads as whole rows, a fraction cut off", arguments: [
        ("1234.0", 1_234), ("1234", 1_234), ("12.7", 12), ("1.5e+18", 1_500_000_000_000_000_000), ("0.0", 0),
    ] as [(String, Int)])
    func statsRowCount(text: String, count: Int) {
        #expect(TrinoIntrospectionSQL.rowCount(fromStatsValue: text) == count)
    }

    @Test("A row count that is not a finite number inside Int is no count instead of a crash", arguments: [
        "NaN", "Infinity", "-Infinity", "1e+30", "-1e+30", "1e19", "9223372036854775807", "rows", "",
    ])
    func unusableStatsRowCount(text: String) {
        #expect(TrinoIntrospectionSQL.rowCount(fromStatsValue: text) == nil)
    }
}
