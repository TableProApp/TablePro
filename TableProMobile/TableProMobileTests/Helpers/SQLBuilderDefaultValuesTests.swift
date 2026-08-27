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

    @Test("the PostgreSQL family, SQLite, SQL Server and DuckDB take DEFAULT VALUES")
    func defaultValuesDialects() {
        for type in [DatabaseType.postgresql, .redshift, .sqlite, .mssql, .duckdb] {
            #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "\"t\"", for: type)
                == "INSERT INTO \"t\" DEFAULT VALUES")
        }
    }

    @Test("Oracle has no all-defaults statement")
    func oracleHasNoForm() {
        #expect(SQLBuilder.buildAllDefaultsInsert(qualifiedTable: "\"t\"", for: .oracle) == nil)
        #expect(!SQLBuilder.supportsAllDefaultsInsert(.oracle))
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
    }
}
