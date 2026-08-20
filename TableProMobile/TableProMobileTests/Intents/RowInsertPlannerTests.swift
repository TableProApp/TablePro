import Foundation
import Testing
import TableProModels
@testable import TableProMobile

@Suite("RowInsertPlanner")
struct RowInsertPlannerTests {
    private let columns = [
        ColumnInfo(name: "id", typeName: "integer", isPrimaryKey: true, isNullable: false, ordinalPosition: 0),
        ColumnInfo(name: "name", typeName: "text", ordinalPosition: 1),
        ColumnInfo(name: "note", typeName: "text", ordinalPosition: 2)
    ]

    private func ansiDriver() -> MockDatabaseDriver {
        MockDatabaseDriver()
    }

    private func backslashDriver() -> MockDatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.usesBackslashEscaping = true
        return driver
    }

    @Test("builds an insert for known columns in table order")
    func buildsInsert() throws {
        let row = PayloadRow(values: ["name": .text("Ada"), "note": .text("hi")])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .postgresql, driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("name", "note") VALUES ('Ada', 'hi')"#])
    }

    @Test("skips an empty primary key so the database can auto-generate it")
    func skipsEmptyPrimaryKey() throws {
        let row = PayloadRow(values: ["id": .text(""), "name": .text("Ada")])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .postgresql, driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("name") VALUES ('Ada')"#])
    }

    @Test("includes a provided primary key value")
    func includesProvidedPrimaryKey() throws {
        let row = PayloadRow(values: ["id": .text("5"), "name": .text("Ada")])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .postgresql, driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("id", "name") VALUES ('5', 'Ada')"#])
    }

    @Test("writes NULL for null values")
    func nullValue() throws {
        let row = PayloadRow(values: ["name": .text("Ada"), "note": .null])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .postgresql, driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("name", "note") VALUES ('Ada', NULL)"#])
    }

    @Test("rejects a column that the table does not have")
    func unknownColumnThrows() throws {
        let row = PayloadRow(values: ["name": .text("Ada"), "missing": .text("x")])
        let driver = ansiDriver()
        #expect(throws: IntentDataError.self) {
            _ = try RowInsertPlanner.statements(
                table: "people", schema: nil, type: .postgresql, driver: driver, columns: columns, rows: [row]
            )
        }
    }

    @Test("throws when the table has no columns")
    func noColumnsThrows() throws {
        let row = PayloadRow(values: ["name": .text("Ada")])
        let driver = ansiDriver()
        #expect(throws: IntentDataError.self) {
            _ = try RowInsertPlanner.statements(
                table: "people", schema: nil, type: .postgresql, driver: driver, columns: [], rows: [row]
            )
        }
    }

    @Test("produces no statement for a row that only sets an empty primary key")
    func emptyRowProducesNoStatement() throws {
        let row = PayloadRow(values: ["id": .text("")])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .postgresql, driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements.isEmpty)
    }

    @Test("escapes single quotes in values")
    func escapesQuotes() throws {
        let row = PayloadRow(values: ["name": .text("O'Hara")])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .mysql, driver: backslashDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO `people` (`name`) VALUES ('O''Hara')"#])
    }

    @Test("qualifies the table with the chosen schema so the row cannot land in the default one")
    func qualifiesWithSchema() throws {
        let row = PayloadRow(values: ["name": .text("Ada")])
        let statements = try RowInsertPlanner.statements(
            table: "events", schema: "reporting", type: .postgresql,
            driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "reporting"."events" ("name") VALUES ('Ada')"#])
    }

    @Test("qualifies with SQL Server bracket quoting")
    func qualifiesWithSchemaOnSQLServer() throws {
        let row = PayloadRow(values: ["name": .text("Ada")])
        let statements = try RowInsertPlanner.statements(
            table: "events", schema: "sales", type: .mssql,
            driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == ["INSERT INTO [sales].[events] ([name]) VALUES ('Ada')"])
    }

    @Test("leaves a backslash alone on a database that does not treat it as an escape")
    func keepsBackslashOnAnsiDialect() throws {
        let row = PayloadRow(values: ["name": .text(#"C:\Users\dat"#)])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .postgresql, driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("name") VALUES ('C:\Users\dat')"#])
    }

    @Test("keeps a newline as a newline on a database that does not treat it as an escape")
    func keepsNewlineOnAnsiDialect() throws {
        let row = PayloadRow(values: ["name": .text("line1\nline2")])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .sqlite, driver: ansiDriver(), columns: columns, rows: [row]
        )
        #expect(statements == ["INSERT INTO \"people\" (\"name\") VALUES ('line1\nline2')"])
    }

    @Test("still escapes backslashes on MySQL, where they are an escape character")
    func escapesBackslashOnMySQL() throws {
        let row = PayloadRow(values: ["name": .text(#"C:\Users\dat"#)])
        let statements = try RowInsertPlanner.statements(
            table: "people", schema: nil, type: .mysql, driver: backslashDriver(), columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO `people` (`name`) VALUES ('C:\\Users\\dat')"#])
    }
}
