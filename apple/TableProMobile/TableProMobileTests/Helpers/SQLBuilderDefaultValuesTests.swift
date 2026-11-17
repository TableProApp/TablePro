import Foundation
import TableProModels
import Testing
@testable import TableProMobile

@Suite("SQLBuilder all-defaults insert")
struct SQLBuilderDefaultValuesTests {
    @Test("MySQL and MariaDB take an empty column list")
    func mySQLFamily() {
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "`t`", for: .mysql)
            == "INSERT INTO `t` () VALUES ()")
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "`t`", for: .mariadb)
            == "INSERT INTO `t` () VALUES ()")
    }

    @Test("TiDB speaks the MySQL dialect and takes an empty column list")
    func tiDBTakesEmptyColumnList() {
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "`t`", for: .tidb)
            == "INSERT INTO `t` () VALUES ()")
        #expect(SQLBuilder.quoteIdentifier("a`b", for: .tidb) == "`a``b`")
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "`t`", for: .oceanbase)
            == "INSERT INTO `t` () VALUES ()")
        #expect(SQLBuilder.speaksMySQLDialect(.oceanbase))
    }

    @Test("Databend is not a MySQL dialect on iOS")
    func databendIsNotMySQLDialect() {
        #expect(!SQLBuilder.speaksMySQLDialect(.databend))
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "\"t\"", for: .databend) == nil)
    }

    @Test("the PostgreSQL family, SQLite, SQL Server and DuckDB take DEFAULT VALUES")
    func defaultValuesDialects() {
        for type in [DatabaseType.postgresql, .redshift, .sqlite, .mssql, .duckdb] {
            #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "\"t\"", for: type)
                == "INSERT INTO \"t\" DEFAULT VALUES")
        }
    }

    // Without it an Insert Row that leaves every column to its default built no statement on D1.
    @Test("Every engine that runs SQLite takes DEFAULT VALUES", arguments: [DatabaseType.cloudflareD1, .libsql, .turso])
    func sqliteFamilyTakesDefaultValues(type: DatabaseType) {
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "\"t\"", for: type) == "INSERT INTO \"t\" DEFAULT VALUES")
        #expect(SQLBuilder.supportsAllDefaultsInsert(type))
    }

    // D12: the macOS spelling through the shared `AllDefaultsInsert`; it needs a column to name, so none without one.
    @Test("Oracle names its first writable column with VALUES (DEFAULT)")
    func oracleNamesAColumn() {
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "\"T\"", for: .oracle, firstWritableColumn: "ID")
            == "INSERT INTO \"T\" (\"ID\") VALUES (DEFAULT)")
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "\"T\"", for: .oracle) == nil)
        #expect(SQLBuilder.supportsAllDefaultsInsert(.oracle))
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "t", for: .clickhouse, firstWritableColumn: "id") == nil)
    }

    @Test("an empty column list routes through the all-defaults form")
    func emptyColumnListRoutes() {
        let driver = MockDatabaseDriver()
        #expect(SQLBuilder.buildInsert(
            table: "people", schema: nil, type: .postgresql, driver: driver, columns: [], values: []
        ) == "INSERT INTO \"people\" DEFAULT VALUES")
        #expect(SQLBuilder.buildInsert(
            table: "people", schema: nil, type: .oracle, driver: driver, columns: [], values: []
        ) == nil)
        #expect(SQLBuilder.buildInsert(
            table: "PEOPLE", schema: nil, type: .oracle, driver: driver, columns: [], values: [], firstWritableColumn: "ID"
        ) == "INSERT INTO \"PEOPLE\" (\"ID\") VALUES (DEFAULT)")
    }
}
