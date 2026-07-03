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

    @Test("builds an insert for known columns in table order")
    func buildsInsert() throws {
        let row = PayloadRow(values: ["name": .text("Ada"), "note": .text("hi")])
        let statements = try RowInsertPlanner.statements(
            table: "people", type: .postgresql, columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("name", "note") VALUES ('Ada', 'hi')"#])
    }

    @Test("skips an empty primary key so the database can auto-generate it")
    func skipsEmptyPrimaryKey() throws {
        let row = PayloadRow(values: ["id": .text(""), "name": .text("Ada")])
        let statements = try RowInsertPlanner.statements(
            table: "people", type: .postgresql, columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("name") VALUES ('Ada')"#])
    }

    @Test("includes a provided primary key value")
    func includesProvidedPrimaryKey() throws {
        let row = PayloadRow(values: ["id": .text("5"), "name": .text("Ada")])
        let statements = try RowInsertPlanner.statements(
            table: "people", type: .postgresql, columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("id", "name") VALUES ('5', 'Ada')"#])
    }

    @Test("writes NULL for null values")
    func nullValue() throws {
        let row = PayloadRow(values: ["name": .text("Ada"), "note": .null])
        let statements = try RowInsertPlanner.statements(
            table: "people", type: .postgresql, columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO "people" ("name", "note") VALUES ('Ada', NULL)"#])
    }

    @Test("rejects a column that the table does not have")
    func unknownColumnThrows() throws {
        let row = PayloadRow(values: ["name": .text("Ada"), "missing": .text("x")])
        #expect(throws: IntentDataError.self) {
            _ = try RowInsertPlanner.statements(table: "people", type: .postgresql, columns: columns, rows: [row])
        }
    }

    @Test("throws when the table has no columns")
    func noColumnsThrows() throws {
        let row = PayloadRow(values: ["name": .text("Ada")])
        #expect(throws: IntentDataError.self) {
            _ = try RowInsertPlanner.statements(table: "people", type: .postgresql, columns: [], rows: [row])
        }
    }

    @Test("produces no statement for a row that only sets an empty primary key")
    func emptyRowProducesNoStatement() throws {
        let row = PayloadRow(values: ["id": .text("")])
        let statements = try RowInsertPlanner.statements(
            table: "people", type: .postgresql, columns: columns, rows: [row]
        )
        #expect(statements.isEmpty)
    }

    @Test("escapes single quotes in values")
    func escapesQuotes() throws {
        let row = PayloadRow(values: ["name": .text("O'Hara")])
        let statements = try RowInsertPlanner.statements(
            table: "people", type: .mysql, columns: columns, rows: [row]
        )
        #expect(statements == [#"INSERT INTO `people` (`name`) VALUES ('O''Hara')"#])
    }
}
