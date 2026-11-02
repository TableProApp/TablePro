import TableProCoreTypes
import Testing

@Test("The engines that run SQLite itself are its family", arguments: [
    DatabaseType.sqlite, .cloudflareD1, .libsql, .turso
])
func runsSQLite(type: DatabaseType) {
    #expect(type.isSQLiteFamily)
}

// PluginKit's SqlDialect files DuckDB under SQLite, yet DuckDB types and compares values its own way.
@Test("An engine that does not run SQLite is not its family", arguments: [
    DatabaseType.duckdb, .postgresql, .mysql, .clickhouse
])
func doesNotRunSQLite(type: DatabaseType) {
    #expect(!type.isSQLiteFamily)
}
