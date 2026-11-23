//
//  CheckListDDLReadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct CheckListDDLReadTests {
    private static let ddl = "CREATE TABLE orders (status TEXT CHECK (status IN ('open', 'closed')))"
    private static let status = ColumnInfo(name: "status", dataType: "TEXT", isNullable: true, isPrimaryKey: false)
    private static let listedStatus = ColumnInfo(
        name: "status", dataType: "TEXT", isNullable: true, isPrimaryKey: false, allowedValues: ["new", "done"]
    )

    private func enumValues(type: DatabaseType, columns: [ColumnInfo]) async -> (values: [String: [String]], ddlReads: Int) {
        let driver = MockDatabaseDriver()
        driver.tableDDLToReturn = ["orders": Self.ddl]
        let connection = TestFixtures.makeConnection(database: "db", type: type)
        let fixture = CoordinatorFixture(connection: connection, driver: driver)
        let scope = DatabaseScope(connectionId: connection.id, database: "db", schema: nil, isSessionBound: true)
        let values = await fixture.coordinator.fetchEnumValues(
            columnInfo: columns, tableName: "orders", connectionType: type, scope: scope
        )
        return (values, driver.fetchTableDDLCallCount)
    }

    @Test(
        "An engine whose stored DDL cannot state the list, or whose driver fills it, reads no DDL",
        arguments: [DatabaseType.postgresql, .pglite, .mysql, .mariadb, .mssql, .clickhouse, .duckdb, .sqlite]
    )
    func skipsTheRead(type: DatabaseType) async {
        let result = await enumValues(type: type, columns: [Self.status])

        #expect(result.ddlReads == 0)
        #expect(result.values.isEmpty)
    }

    @Test(
        "An engine that can store the list, or one nobody curated, still reads the DDL",
        arguments: [DatabaseType.cockroachdb, .libsql, DatabaseType(rawValue: "UncuratedSQLEngine")]
    )
    func keepsTheRead(type: DatabaseType) async {
        let result = await enumValues(type: type, columns: [Self.status])

        #expect(result.ddlReads == 1)
        #expect(result.values == ["status": ["open", "closed"]])
    }

    @Test(
        "A column that carries its own values needs no DDL read",
        arguments: [DatabaseType.cockroachdb, .libsql, .sqlite, DatabaseType(rawValue: "UncuratedSQLEngine")]
    )
    func columnValuesAnswer(type: DatabaseType) async {
        let result = await enumValues(type: type, columns: [Self.listedStatus])

        #expect(result.ddlReads == 0)
        #expect(result.values == ["status": ["new", "done"]])
    }
}
