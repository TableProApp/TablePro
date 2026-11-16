import TableProPluginKit
import Testing

struct SqlDialectTests {
    @Test("Dialect.from maps known database type ids")
    func dialect_from_database_type_id() {
        #expect(SqlDialect.from(databaseTypeId: "PostgreSQL") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Redshift") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Greenplum") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "AlloyDB") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "Citus") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "CockroachDB") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "PGlite") == .postgres)
        #expect(SqlDialect.from(databaseTypeId: "MySQL") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "MariaDB") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "TiDB") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "Databend") == .generic)
        #expect(SqlDialect.from(databaseTypeId: "SQLite") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "DuckDB") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "Cloudflare D1") == .sqlite)
        #expect(SqlDialect.from(databaseTypeId: "Oracle") == .oracle)
        #expect(SqlDialect.from(databaseTypeId: "Dameng") == .generic)
        #expect(SqlDialect.from(databaseTypeId: "Unknown Whatever") == .generic)
    }
}
